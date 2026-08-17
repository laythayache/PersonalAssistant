import Foundation

/// Layer 1 of the NLU pipeline: a deterministic grammar over the lexicon.
///
/// It runs on every message, in about a millisecond, offline, in all three input styles. Apple's
/// on-device model only sees the messages this cannot read confidently — and never sees Arabic,
/// because Apple's model does not support it (ARCHITECTURE.md §1).
struct RuleParser {
    var calendar: Calendar
    var defaultReminderHour: Int

    init(calendar: Calendar = .current, defaultReminderHour: Int = 9) {
        self.calendar = calendar
        self.defaultReminderHour = defaultReminderHour
    }

    // MARK: - Entry point

    func parse(_ text: String, now: Date = .now) -> AssistantCommand {
        let normalized = Normalizer.normalize(text)
        var command = AssistantCommand()
        command.originalText = text
        command.detectedScript = normalized.script.rawValue
        command.source = .rules

        guard !normalized.tokens.isEmpty else {
            command.action = .saveNote
            command.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return command
        }

        let concepts = normalized.tokens.map { Lexicon.concepts(for: $0.folded) }
        var state = ScanState(normalized: normalized, concepts: concepts)

        // "What's next?" is a whole-phrase idiom in every one of the three input styles, so it is
        // matched before the word-by-word grammar gets a chance to see "next" as a day qualifier.
        if Self.isWhatsNext(normalized.phrase) {
            command.action = .getNextItems
            command.confidence = 0.95
            return command
        }

        let pendingRecurrence = detectRecurrence(&state)
        let atoms = detectAtoms(&state)
        let action = detectAction(state, atoms: atoms)
        command.action = action

        // A postpone or a move carries two times: the one describing the item being moved, and the
        // one it is moving to. "until"/"to"/"لـ" separates them.
        //
        // The split is by *position*, not by marking each atom: in "postpone that until tomorrow at
        // 3" only "tomorrow" carries the marker, but "at 3" is plainly part of the same trailing
        // phrase. Everything from the first marked atom onwards is the new time.
        let newTimeAtoms: [Atom]
        let targetAtoms: [Atom]
        if action == .postponeAlarm || action == .editAlarm || action == .cancelAlarm {
            if let firstMarked = atoms.firstIndex(where: \.untilMarked) {
                newTimeAtoms = Array(atoms[firstMarked...])
                targetAtoms = Array(atoms[..<firstMarked])
            } else if action == .cancelAlarm {
                // Nothing to move to. Any time named describes what to cancel.
                newTimeAtoms = []
                targetAtoms = atoms
            } else {
                // "Move gym 8" with no marker word at all — the single time can only be the new one.
                newTimeAtoms = atoms
                targetAtoms = []
            }
        } else {
            newTimeAtoms = atoms
            targetAtoms = []
        }

        // Resolve the new time.
        let resolver = DateResolver(calendar: calendar, defaultReminderHour: defaultReminderHour)
        var spec = Self.assemble(newTimeAtoms)
        var recurrence = Self.materialise(pendingRecurrence, spec: spec)

        // "Remind me every 3 days to check this" names a rhythm but no time. Anchor it to today so
        // the resolver applies the default hour and rolls forward, rather than refusing to resolve.
        if spec.isEmpty, recurrence.isRepeating || !Self.isNoRecurrence(pendingRecurrence) {
            spec.dayAnchor = .today
        }

        // A weekly rule with no day named in the sentence ("every Monday at 9") should first fire
        // on the soonest listed weekday, not today.
        if case .weekly(let days) = recurrence, spec.dayAnchor == .unspecified, !days.isEmpty {
            spec.dayAnchor = Self.soonestWeekday(days, spec: spec, resolver: resolver, now: now)
        }

        if let resolved = resolver.resolve(spec, now: now) {
            command.scheduledAt = resolved.date
            command.meridiemWasGuessed = resolved.meridiemWasGuessed
            command.timeWasDefaulted = resolved.timeWasDefaulted
            command.rolledForward = resolved.rolledForward
            recurrence = Self.materialise(pendingRecurrence, spec: spec, resolvedDate: resolved.date, calendar: calendar)
        }
        command.recurrence = recurrence

        // Resolve the time that describes the *existing* item.
        if !targetAtoms.isEmpty {
            let targetSpec = Self.assemble(targetAtoms)
            command.targetHasClock = targetSpec.clock != nil
            command.targetAt = resolver.resolve(targetSpec, now: now)?.date
        }

        // Whatever is left over is the user's own description.
        let leftover = extractPhrase(state)
        switch action {
        case .cancelAlarm, .postponeAlarm, .editAlarm, .markCompleted, .markMissed:
            command.targetQuery = leftover.isEmpty ? nil : leftover
            command.title = leftover
        case .createAlarm:
            command.title = leftover.isEmpty ? Self.fallbackTitle(state) : leftover
        case .saveNote:
            command.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            command.title = leftover
        }

        command.projectName = detectExplicitProject(state)
        command.confidence = Self.score(command: command, state: state, atoms: atoms)
        return command
    }

    // MARK: - Scan state

    private struct ScanState {
        let normalized: NormalizedText
        let concepts: [Set<Concept>]
        /// Tokens absorbed by a recurrence rule or a time atom. Verbs and glue are *not* listed
        /// here; they are recognised by concept when the title is trimmed.
        var consumed: Set<Int> = []

        var count: Int { normalized.tokens.count }

        func has(_ concept: Concept, at index: Int) -> Bool {
            guard concepts.indices.contains(index) else { return false }
            return concepts[index].contains(concept)
        }

        func hasAny(_ wanted: Set<Concept>, at index: Int) -> Bool {
            guard concepts.indices.contains(index) else { return false }
            return !concepts[index].isDisjoint(with: wanted)
        }

        func weekday(at index: Int) -> Int? {
            guard concepts.indices.contains(index) else { return nil }
            for concept in concepts[index] {
                if case .weekday(let value) = concept { return value }
            }
            return nil
        }

        func number(at index: Int) -> Int? {
            guard normalized.tokens.indices.contains(index) else { return nil }
            return Lexicon.numericValue(of: normalized.tokens[index].folded)
        }

        func unit(at index: Int) -> OffsetUnit? {
            guard concepts.indices.contains(index) else { return nil }
            if concepts[index].contains(.unitMinute) { return .minute }
            if concepts[index].contains(.unitHour) { return .hour }
            if concepts[index].contains(.unitDay) { return .day }
            if concepts[index].contains(.unitWeek) { return .week }
            if concepts[index].contains(.unitMonth) { return .month }
            if concepts[index].contains(.unitYear) { return .year }
            return nil
        }

        func partOfDay(at index: Int) -> PartOfDay? {
            guard concepts.indices.contains(index) else { return nil }
            if concepts[index].contains(.midnight) { return .midnight }
            if concepts[index].contains(.morning) { return .morning }
            if concepts[index].contains(.noon) { return .noon }
            if concepts[index].contains(.afternoon) { return .afternoon }
            if concepts[index].contains(.evening) { return .evening }
            if concepts[index].contains(.night) { return .night }
            return nil
        }

        /// The next index at or after `from` that is not a filler word.
        func skippingFiller(from index: Int) -> Int {
            var i = index
            while i < count, concepts[i].contains(.filler) { i += 1 }
            return i
        }
    }

    private struct Atom {
        enum Payload {
            case day(DayAnchor)
            case clock(ClockTime)
            case part(PartOfDay)
            case relative(RelativeOffset)
        }
        var payload: Payload
        var range: ClosedRange<Int>
        var untilMarked: Bool
    }

    // MARK: - Recurrence

    private enum PendingRecurrence {
        case none
        case fixed(RecurrenceRule)
        /// "every week" — the weekday is whichever day the first occurrence lands on.
        case weeklyOnResolvedDay
        /// "every month" — the day-of-month comes from the first occurrence.
        case monthlyOnResolvedDay
    }

    private func detectRecurrence(_ state: inout ScanState) -> PendingRecurrence {
        for i in 0..<state.count where !state.consumed.contains(i) {
            // "daily" / "everyday" / "يوميا" needs no companion word.
            if state.has(.daily, at: i) && !state.has(.every, at: i - 1) {
                state.consumed.insert(i)
                return .fixed(.weekly(days: RecurrenceRule.allDaysOfWeek))
            }
            guard state.has(.every, at: i) else { continue }

            var j = state.skippingFiller(from: i + 1)
            guard j < state.count else { continue }

            // every Monday [and Wednesday ...]
            var days: Set<Int> = []
            var scan = j
            while scan < state.count, let weekday = state.weekday(at: scan) {
                days.insert(weekday)
                scan = state.skippingFiller(from: scan + 1)
            }
            if !days.isEmpty {
                for k in i..<scan { state.consumed.insert(k) }
                return .fixed(.weekly(days: days))
            }

            if state.has(.weekdaysWord, at: j) {
                state.consumed.formUnion([i, j])
                return .fixed(.weekly(days: RecurrenceRule.allWeekdays))
            }
            if state.has(.weekendWord, at: j) {
                state.consumed.formUnion([i, j])
                return .fixed(.weekly(days: [1, 7]))
            }

            // every 3 days / every 2 weeks
            var multiplier = 1
            if let value = state.number(at: j), state.weekday(at: j) == nil {
                multiplier = max(value, 1)
                j = state.skippingFiller(from: j + 1)
            }
            if let unit = state.unit(at: j) {
                for k in i...j { state.consumed.insert(k) }
                switch unit {
                case .day:
                    return multiplier == 1
                        ? .fixed(.weekly(days: RecurrenceRule.allDaysOfWeek))
                        : .fixed(.everyNDays(multiplier))
                case .week:
                    return multiplier == 1 ? .weeklyOnResolvedDay : .fixed(.everyNDays(multiplier * 7))
                case .month:
                    return .monthlyOnResolvedDay
                case .year:
                    return .fixed(.yearly)
                case .hour, .minute:
                    // AlarmKit cannot repeat sub-daily, and neither will this app pretend to.
                    return .none
                }
            }
        }
        return .none
    }

    private static func isNoRecurrence(_ pending: PendingRecurrence) -> Bool {
        if case .none = pending { return true }
        if case .fixed(let rule) = pending, rule == .none { return true }
        return false
    }

    private static func materialise(_ pending: PendingRecurrence,
                                    spec: TimeSpec,
                                    resolvedDate: Date? = nil,
                                    calendar: Calendar = .current) -> RecurrenceRule {
        switch pending {
        case .none:
            return .none
        case .fixed(let rule):
            return rule
        case .weeklyOnResolvedDay:
            guard let date = resolvedDate else { return .none }
            return .weekly(days: [calendar.component(.weekday, from: date)])
        case .monthlyOnResolvedDay:
            guard let date = resolvedDate else { return .none }
            return .monthlyOnDay(calendar.component(.day, from: date))
        }
    }

    // MARK: - Time atoms

    private func detectAtoms(_ state: inout ScanState) -> [Atom] {
        var atoms: [Atom] = []
        var i = 0

        while i < state.count {
            if state.consumed.contains(i) { i += 1; continue }

            // "in ..." / "ba3d ..." / "بعد ..."
            if state.has(.within, at: i) {
                let next = state.skippingFiller(from: i + 1)

                if state.has(.tomorrow, at: next) {
                    atoms.append(make(.day(.dayAfterTomorrow), i...next, state))
                    consume(i...next, &state); i = next + 1; continue
                }
                if state.partOfDay(at: next) == .noon {
                    atoms.append(make(.part(.afternoon), i...next, state))
                    consume(i...next, &state); i = next + 1; continue
                }
                if let atom = scanRelative(from: i, state: state) {
                    atoms.append(atom)
                    consume(atom.range, &state); i = atom.range.upperBound + 1; continue
                }
            }

            // "7:30"
            if let clock = colonClock(at: i, state: state) {
                var atom = make(.clock(clock.time), i...i, state)
                let end = decorate(&atom, clockStart: i, state: state)
                atoms.append(atom)
                consume(i...end, &state); i = end + 1; continue
            }

            let hasWeekday = state.weekday(at: i) != nil
            let precededByOclock = state.has(.oclock, at: i - 1)

            // "tanen"/"تنين" is both Monday and the number two. A clock marker immediately before
            // it settles the argument; otherwise the weekday reading wins.
            if hasWeekday && !precededByOclock {
                let qualifier: WeekdayQualifier =
                    (state.has(.nextMarker, at: i - 1) || state.has(.nextMarker, at: i + 1)) ? .next : .soonest
                atoms.append(make(.day(.weekday(state.weekday(at: i)!, qualifier)), i...i, state))
                state.consumed.insert(i); i += 1; continue
            }

            if let value = state.number(at: i) {
                // A number followed by a unit is a duration, not a clock reading.
                let next = state.skippingFiller(from: i + 1)
                if let unit = state.unit(at: next), !state.has(.oclock, at: next) {
                    atoms.append(make(.relative(RelativeOffset(unit: unit, value: value)), i...next, state))
                    consume(i...next, &state); i = next + 1; continue
                }
                if (0...23).contains(value) {
                    var atom = make(.clock(ClockTime(hour: value)), i...i, state)
                    let end = decorate(&atom, clockStart: i, state: state)
                    atoms.append(atom)
                    consume(i...end, &state); i = end + 1; continue
                }
                // Numbers above 23 are part of what the user is describing. Leave them alone.
            }

            if state.has(.today, at: i) || state.has(.tonight, at: i) {
                atoms.append(make(.day(.today), i...i, state))
                if state.has(.tonight, at: i) {
                    atoms.append(make(.part(.evening), i...i, state))
                }
                state.consumed.insert(i); i += 1; continue
            }
            if state.has(.tomorrow, at: i) {
                atoms.append(make(.day(.tomorrow), i...i, state))
                state.consumed.insert(i); i += 1; continue
            }
            if state.has(.yesterday, at: i) {
                atoms.append(make(.day(.yesterday), i...i, state))
                state.consumed.insert(i); i += 1; continue
            }
            if let part = state.partOfDay(at: i) {
                atoms.append(make(.part(part), i...i, state))
                state.consumed.insert(i); i += 1; continue
            }

            i += 1
        }
        return atoms
    }

    /// Reads minutes and meridiem that trail a bare hour. Returns the last index absorbed.
    private func decorate(_ atom: inout Atom, clockStart: Int, state: ScanState) -> Int {
        guard case .clock(var time) = atom.payload else { return clockStart }
        var end = clockStart

        // "sab3a w nos" / "7 and a half" / "4 illa rob3"
        var j = state.skippingFiller(from: clockStart + 1)
        if state.has(.minusMarker, at: j) {
            let k = state.skippingFiller(from: j + 1)
            if state.has(.quarter, at: k) {
                time.hour = time.hour == 0 ? 23 : time.hour - 1
                time.minute = 45
                end = k
                j = state.skippingFiller(from: k + 1)
            }
        } else if state.has(.half, at: j) {
            time.minute = 30; end = j; j = state.skippingFiller(from: j + 1)
        } else if state.has(.quarter, at: j) {
            time.minute = 15; end = j; j = state.skippingFiller(from: j + 1)
        }

        // Meridiem and part-of-day may sit on either side: "8 pm", "masa 8", "4 بالمسا".
        for candidate in [j, clockStart + 1, clockStart - 1, clockStart - 2] where candidate >= 0 && candidate < state.count {
            if state.has(.am, at: candidate) { time.meridiem = .am; end = max(end, candidate); break }
            if state.has(.pm, at: candidate) { time.meridiem = .pm; end = max(end, candidate); break }
        }

        atom.payload = .clock(time)
        return end
    }

    private func colonClock(at index: Int, state: ScanState) -> (time: ClockTime, end: Int)? {
        guard state.normalized.tokens.indices.contains(index) else { return nil }
        let folded = state.normalized.tokens[index].folded
        guard folded.contains(":") else { return nil }
        let parts = folded.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (ClockTime(hour: hour, minute: minute), index)
    }

    private func scanRelative(from index: Int, state: ScanState) -> Atom? {
        var j = state.skippingFiller(from: index + 1)
        var value = 1
        var isHalf = false

        if state.has(.half, at: j) {
            isHalf = true
            j = state.skippingFiller(from: j + 1)
        } else if let number = state.number(at: j) {
            value = number
            j = state.skippingFiller(from: j + 1)
        }

        guard let unit = state.unit(at: j) else { return nil }
        if isHalf {
            // "in half an hour"
            let minutes = unit == .hour ? 30 : (unit == .day ? 720 : 30)
            return make(.relative(RelativeOffset(unit: .minute, value: minutes)), index...j, state)
        }
        return make(.relative(RelativeOffset(unit: unit, value: value)), index...j, state)
    }

    private func make(_ payload: Atom.Payload, _ range: ClosedRange<Int>, _ state: ScanState) -> Atom {
        Atom(payload: payload, range: range, untilMarked: Self.isUntilMarked(range.lowerBound, state))
    }

    private func consume(_ range: ClosedRange<Int>, _ state: inout ScanState) {
        for k in range where k >= 0 && k < state.count { state.consumed.insert(k) }
    }

    /// True when "until", "till", "to", "لـ" introduces this atom.
    ///
    /// The marker can be a separate word ("to Friday") or fused onto the front of it — Arabic
    /// writes "to Friday" as one token, "للجمعة", and `Lexicon` reports both meanings for it.
    private static func isUntilMarked(_ start: Int, _ state: ScanState) -> Bool {
        if state.has(.untilMarker, at: start) { return true }
        for offset in 1...2 {
            let index = start - offset
            guard index >= 0 else { break }
            if state.has(.untilMarker, at: index) { return true }
            // Only skip over filler on the way back; any other word breaks the link.
            if !state.has(.filler, at: index) && offset == 1 && !state.has(.oclock, at: index) { break }
        }
        return false
    }

    private static func assemble(_ atoms: [Atom]) -> TimeSpec {
        var spec = TimeSpec()
        for atom in atoms {
            switch atom.payload {
            case .day(let anchor):
                if spec.dayAnchor == .unspecified { spec.dayAnchor = anchor }
            case .clock(let clock):
                if spec.clock == nil { spec.clock = clock }
            case .part(let part):
                if spec.partOfDay == nil { spec.partOfDay = part }
            case .relative(let offset):
                if spec.relative == nil { spec.relative = offset }
            }
        }
        // "tomorrow in 5 minutes" is nonsense; an explicit day wins over a relative offset.
        if spec.dayAnchor != .unspecified || spec.clock != nil {
            if spec.clock != nil || spec.partOfDay != nil { spec.relative = nil }
        }
        return spec
    }

    private static func soonestWeekday(_ days: Set<Int>,
                                       spec: TimeSpec,
                                       resolver: DateResolver,
                                       now: Date) -> DayAnchor {
        var best: (day: Int, date: Date)?
        for day in days.sorted() {
            var probe = spec
            probe.dayAnchor = .weekday(day, .soonest)
            guard let resolved = resolver.resolve(probe, now: now) else { continue }
            if best == nil || resolved.date < best!.date {
                best = (day, resolved.date)
            }
        }
        guard let best else { return .unspecified }
        return .weekday(best.day, .soonest)
    }

    // MARK: - Action

    private func detectAction(_ state: ScanState, atoms: [Atom]) -> AssistantAction {
        var sawCancel = false, sawPostpone = false, sawMove = false
        var sawDone = false, sawMissed = false, sawList = false, sawQuestion = false
        var sawCreate = false, sawAlarmNoun = false

        for i in 0..<state.count {
            let c = state.concepts[i]
            if c.contains(.verbCancel) { sawCancel = true }
            if c.contains(.verbPostpone) { sawPostpone = true }
            if c.contains(.verbMove) { sawMove = true }
            if c.contains(.verbDone) { sawDone = true }
            if c.contains(.verbMissed) { sawMissed = true }
            if c.contains(.verbList) { sawList = true }
            if c.contains(.questionWord) { sawQuestion = true }
            if c.contains(.verbRemind) || c.contains(.verbCreate) || c.contains(.verbWake) { sawCreate = true }
            if c.contains(.nounAlarm) { sawAlarmNoun = true }
        }

        if sawCancel { return .cancelAlarm }
        if sawPostpone { return .postponeAlarm }
        if sawMove { return atoms.contains(where: \.untilMarked) ? .postponeAlarm : .editAlarm }
        if sawDone { return .markCompleted }
        if sawMissed { return .markMissed }
        if (sawList || sawQuestion) && sawAlarmNoun { return .listAlarms }
        if sawCreate || sawAlarmNoun { return .createAlarm }
        // No verb at all, but a real time was named — "tomorrow 4pm dentist".
        if atoms.contains(where: { if case .part = $0.payload { return false } else { return true } }) {
            return .createAlarm
        }
        return .saveNote
    }

    private static func isWhatsNext(_ phrase: String) -> Bool {
        let idioms = ["whats next", "what is next", "what next", "whats up next", "next up",
                      "whats coming", "what do i have next",
                      "shu ba3d", "shu fi ba3d", "shu jay", "shu eljay", "shou ba3d",
                      "شو بعد", "شو التالي", "شو الجاي", "شو في بعد", "ايش بعدين", "شو بعدين"]
        if idioms.contains(where: { phrase.contains($0) }) { return true }
        return phrase == "next" || phrase == "ba3d" || phrase == "التالي"
    }

    // MARK: - Leftover text

    /// Concepts that are scaffolding rather than content. Trimmed from the ends of the title so the
    /// user's own phrasing survives in the middle — "send the report" keeps its "the".
    private static let glue: Set<Concept> = [
        .filler, .oclock, .within, .untilMarker, .forMarker, .nextMarker,
        .questionWord, .nounAlarm, .every, .daily, .am, .pm, .half, .quarter, .minusMarker,
        .verbRemind, .verbCreate, .verbWake, .verbCancel, .verbPostpone, .verbMove,
        .verbList, .verbDone, .verbMissed,
        .unitMinute, .unitHour, .unitDay, .unitWeek, .unitMonth, .unitYear
    ]

    /// "this" is scaffolding in front ("this Friday") and content behind ("check this"), so it is
    /// only trimmed from the left.
    private static let leadingOnlyGlue: Set<Concept> = [.thisMarker]

    private func extractPhrase(_ state: ScanState) -> String {
        var runs: [[Int]] = []
        var current: [Int] = []

        for i in 0..<state.count {
            if state.consumed.contains(i) {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(i)
            }
        }
        if !current.isEmpty { runs.append(current) }

        var best: [Int] = []
        for run in runs {
            let trimmed = trimGlue(run, state)
            if trimmed.count > best.count { best = trimmed }
        }
        guard !best.isEmpty else { return "" }

        return best.map { state.normalized.tokens[$0].original }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimGlue(_ run: [Int], _ state: ScanState) -> [Int] {
        var indices = run
        while let first = indices.first, isGlue(first, state, leading: true) { indices.removeFirst() }
        while let last = indices.last, isGlue(last, state, leading: false) { indices.removeLast() }
        return indices
    }

    private func isGlue(_ index: Int, _ state: ScanState, leading: Bool) -> Bool {
        guard state.concepts.indices.contains(index) else { return false }
        let c = state.concepts[index]
        if c.isEmpty { return false }
        let set = leading ? Self.glue.union(Self.leadingOnlyGlue) : Self.glue
        return !c.isDisjoint(with: set)
    }

    private static func fallbackTitle(_ state: ScanState) -> String {
        for i in 0..<state.count {
            if state.concepts[i].contains(.verbWake) { return "Wake up" }
        }
        return "Alarm"
    }

    /// Only an explicit "project X" is honoured here. Matching a bare word against the user's real
    /// project list needs the store, so it happens in `CommandExecutor` — requirement 8 says the
    /// assistant must never invent project meaning.
    private func detectExplicitProject(_ state: ScanState) -> String? {
        for i in 0..<state.count {
            let folded = state.normalized.tokens[i].folded
            guard folded == "project" || folded == "مشروع" else { continue }
            let next = i + 1
            guard next < state.count, !state.consumed.contains(next) else { continue }
            return state.normalized.tokens[next].original
        }
        return nil
    }

    // MARK: - Confidence

    private static func score(command: AssistantCommand, state: ScanState, atoms: [Atom]) -> Double {
        var score = 0.0

        let explicitVerb = (0..<state.count).contains { i in
            !state.concepts[i].isDisjoint(with: Set<Concept>([
                .verbRemind, .verbCreate, .verbWake, .verbCancel, .verbPostpone,
                .verbMove, .verbList, .verbDone, .verbMissed, .nounAlarm
            ]))
        }
        score += explicitVerb ? 0.45 : 0.15

        if command.scheduledAt != nil && !atoms.isEmpty { score += 0.35 }

        switch command.action {
        case .cancelAlarm, .postponeAlarm, .editAlarm, .markCompleted, .markMissed:
            if command.targetQuery?.isEmpty == false || command.targetAt != nil { score += 0.2 }
        case .createAlarm:
            if !command.title.isEmpty && command.title != "Alarm" { score += 0.2 }
        case .getNextItems, .listAlarms:
            score += 0.2
        default:
            break
        }

        // Nothing actionable was found at all.
        if command.action == .saveNote { return min(score, 0.3) }

        return min(score, 1.0)
    }
}
