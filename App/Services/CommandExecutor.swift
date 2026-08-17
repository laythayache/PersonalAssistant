import Foundation
import SwiftData

/// Validates a typed command and performs it. This is the only place that writes alarm state.
///
/// The language layers produce an `AssistantCommand`; nothing they generate reaches the store or
/// AlarmKit without passing through here first (requirement 15).
@MainActor
final class CommandExecutor {
    private let store: Store
    private let scheduler: AlarmScheduling
    private let review: DailyReviewService
    private let calendar: Calendar
    private let recurrenceEngine: RecurrenceEngine

    /// What "that" refers to. Set every time an alarm is created or acted on.
    var lastReferencedOccurrenceID: UUID?

    init(store: Store,
         scheduler: AlarmScheduling,
         review: DailyReviewService,
         calendar: Calendar = .current) {
        self.store = store
        self.scheduler = scheduler
        self.review = review
        self.calendar = calendar
        self.recurrenceEngine = RecurrenceEngine(calendar: calendar)
    }

    // MARK: - Entry point

    func execute(_ command: AssistantCommand, now: Date = .now) async -> ExecutionOutcome {
        guard command.source != .unparsed else {
            return .fallback(FallbackPrompt(
                originalText: command.originalText,
                bestGuess: command,
                reply: "I saved that but I am not sure what to do with it. Set it up in one tap?"))
        }

        switch command.action {
        case .createAlarm:
            return await create(command, now: now)
        case .cancelAlarm:
            return await cancel(command, now: now)
        case .postponeAlarm:
            return await postpone(command, now: now)
        case .editAlarm:
            return await edit(command, now: now)
        case .listAlarms:
            return list(command, now: now)
        case .getNextItems:
            return next(now: now)
        case .markCompleted:
            return await mark(command, as: .completed, now: now)
        case .markMissed:
            return await mark(command, as: .missed, now: now)
        case .createProject:
            let name = command.projectName ?? command.title
            guard !name.isEmpty else { return .failure("Which project?") }
            let project = store.createProject(named: name)
            return .reply("Project \(Phrasing.isolate(project.name)) created.")
        case .assignProject, .addDailyNote, .saveNote:
            return note(command, now: now)
        }
    }

    // MARK: - Create

    private func create(_ command: AssistantCommand, now: Date, skippingCollisionCheck: Bool = false) async -> ExecutionOutcome {
        guard let firstDate = command.scheduledAt else {
            return .fallback(FallbackPrompt(
                originalText: command.originalText,
                bestGuess: command,
                reply: "When should that go off?"))
        }

        // An explicitly named project that does not exist yet is the one case where the assistant
        // asks before inventing structure — requirement 8.
        if let named = command.projectName, store.project(named: named) == nil {
            return .projectQuestion(ProjectPrompt(
                command: command,
                suggestedName: named,
                reply: "Make \(Phrasing.isolate(named)) a project?"))
        }

        if !skippingCollisionCheck {
            let existing = CollisionDetector.conflicts(at: firstDate, among: store.alarmSlots(from: now))
            if !existing.isEmpty {
                let names = existing.map { Phrasing.isolate($0.title) }.joined(separator: ", ")
                return .collision(CollisionPrompt(
                    command: command,
                    proposedDate: firstDate,
                    existing: existing,
                    reply: "\(names) is already set for \(Phrasing.when(firstDate, now: now, calendar: calendar))."))
            }
        }

        return await materialise(command, firstDate: firstDate, now: now)
    }

    /// Persists the item, its occurrences, and registers them with the system.
    private func materialise(_ command: AssistantCommand, firstDate: Date, now: Date) async -> ExecutionOutcome {
        let project = resolveProject(for: command)
        let title = command.title.isEmpty ? "Alarm" : command.title

        let item = AlarmItem(title: title,
                             originalText: command.originalText,
                             interpretationJSON: command.jsonString,
                             kind: .alarm,
                             recurrence: command.recurrence,
                             project: project)
        store.context.insert(item)
        store.logEvent(.itemCreated, "Created \(title) from: \(command.originalText)", itemID: item.id)

        let dates = recurrenceEngine.schedulableDates(rule: command.recurrence, anchor: firstDate, now: now)
        var firstOccurrenceID: UUID?
        var problem: String?

        if command.recurrence.isNativelySupportedByAlarmKit, case .weekly(let days) = command.recurrence {
            // One system alarm covers the whole series; the store keeps one occurrence at a time
            // and the reconciler rolls it forward as each one fires.
            let occurrence = AlarmOccurrence(scheduledAt: firstDate,
                                             dayKey: DayKey.make(for: firstDate, calendar: calendar),
                                             item: item)
            store.context.insert(occurrence)
            firstOccurrenceID = occurrence.id

            let time = recurrenceEngine.timeComponents(of: firstDate)
            let request = makeRequest(occurrence: occurrence,
                                      item: item,
                                      mode: .weekly(hour: time.hour, minute: time.minute, days: days))
            problem = await register(request, on: occurrence, itemID: item.id)
        } else {
            for date in dates {
                let occurrence = AlarmOccurrence(scheduledAt: date,
                                                 dayKey: DayKey.make(for: date, calendar: calendar),
                                                 item: item)
                store.context.insert(occurrence)
                if firstOccurrenceID == nil { firstOccurrenceID = occurrence.id }

                let request = makeRequest(occurrence: occurrence, item: item, mode: .fixed(date))
                if let failure = await register(request, on: occurrence, itemID: item.id), problem == nil {
                    problem = failure
                }
            }
        }

        store.save("create alarm")
        lastReferencedOccurrenceID = firstOccurrenceID

        for dayKey in Set(dates.map { DayKey.make(for: $0, calendar: calendar) }) {
            await review.reconcileReview(forDayKey: dayKey, now: now)
        }

        var reply = "Set \(Phrasing.isolate(title)) for \(Phrasing.when(firstDate, now: now, calendar: calendar))"
        reply += Phrasing.recurrence(command.recurrence)
        if let project, !project.isDefault { reply += " · \(Phrasing.isolate(project.name))" }
        reply += "."
        if command.rolledForward && command.recurrence == .none {
            reply += " That time had already passed today."
        }
        if command.timeWasDefaulted {
            reply += " No time was given, so I used \(Phrasing.time(firstDate))."
        }
        if let problem { reply += " ⚠︎ \(problem)" }

        return .created(CreatedResult(
            occurrenceID: firstOccurrenceID ?? UUID(),
            reply: reply,
            meridiemAlternative: command.meridiemWasGuessed ? Phrasing.meridiemAlternative(for: firstDate, calendar: calendar) : nil,
            schedulingProblem: problem))
    }

    private func makeRequest(occurrence: AlarmOccurrence,
                             item: AlarmItem,
                             mode: AlarmScheduleRequest.Mode) -> AlarmScheduleRequest {
        AlarmScheduleRequest(id: occurrence.alarmKitID ?? occurrence.id,
                             itemID: item.id,
                             title: item.title,
                             projectName: item.project?.name ?? Constants.defaultProjectName,
                             kind: item.kind,
                             mode: mode,
                             allowSnooze: item.kind != .dailyReview,
                             snoozeMinutes: store.settings().snoozeMinutes)
    }

    /// Returns a human-readable problem, or nil on success. The occurrence is persisted either way
    /// so the reconciler can retry — requirement 17 forbids losing the request.
    private func register(_ request: AlarmScheduleRequest,
                          on occurrence: AlarmOccurrence,
                          itemID: UUID) async -> String? {
        do {
            try await scheduler.schedule(request)
            occurrence.isRegisteredWithAlarmKit = true
            store.logEvent(.occurrenceScheduled,
                           "Scheduled for \(occurrence.scheduledAt).",
                           itemID: itemID, occurrenceID: occurrence.id)
            return nil
        } catch {
            occurrence.isRegisteredWithAlarmKit = false
            let message = (error as? AlarmSchedulingError)?.errorDescription ?? error.localizedDescription
            store.logEvent(.schedulingFailed, message, itemID: itemID, occurrenceID: occurrence.id)
            DebugLog.shared.error("executor", "schedule failed: \(message)")
            return "Saved, but iOS did not accept the alarm: \(message)"
        }
    }

    private func resolveProject(for command: AssistantCommand) -> Project? {
        if let named = command.projectName, let existing = store.project(named: named) { return existing }
        if let mentioned = store.projectMentioned(in: command.title + " " + command.originalText) {
            return mentioned
        }
        return store.defaultProject()
    }

    // MARK: - Collision resolution

    func resolveCollision(_ prompt: CollisionPrompt,
                          with resolution: CollisionResolution,
                          newTime: Date?,
                          now: Date = .now) async -> ExecutionOutcome {
        switch resolution {
        case .keepBoth:
            return await create(prompt.command, now: now, skippingCollisionCheck: true)

        case .replaceExisting:
            for slot in prompt.existing {
                if let occurrence = store.occurrence(id: slot.id) {
                    await cancelOccurrence(occurrence, wholeSeries: false, reason: "Replaced by a new alarm.")
                }
            }
            store.save("replace existing")
            return await create(prompt.command, now: now, skippingCollisionCheck: true)

        case .postponeExisting:
            guard let newTime else { return .failure("Postpone the existing one to when?") }
            var moved: [String] = []
            for slot in prompt.existing {
                guard let occurrence = store.occurrence(id: slot.id) else { continue }
                if await reschedule(occurrenceID: occurrence.id, to: newTime, now: now,
                                    reason: "Postponed to make room for a new alarm.") != nil {
                    moved.append(slot.title)
                }
            }
            let outcome = await create(prompt.command, now: now, skippingCollisionCheck: true)
            guard case .created(let result) = outcome else { return outcome }
            let names = moved.map(Phrasing.isolate).joined(separator: ", ")
            return .created(CreatedResult(occurrenceID: result.occurrenceID,
                                          reply: result.reply + " Moved \(names) to \(Phrasing.when(newTime, now: now, calendar: calendar)).",
                                          meridiemAlternative: result.meridiemAlternative,
                                          schedulingProblem: result.schedulingProblem))

        case .postponeNew:
            guard let newTime else { return .failure("Postpone the new one to when?") }
            var shifted = prompt.command
            shifted.scheduledAt = newTime
            shifted.meridiemWasGuessed = false
            shifted.timeWasDefaulted = false
            return await create(shifted, now: now, skippingCollisionCheck: false)
        }
    }

    // MARK: - Project confirmation

    func answerProjectQuestion(_ prompt: ProjectPrompt, createIt: Bool, now: Date = .now) async -> ExecutionOutcome {
        var command = prompt.command
        if createIt {
            store.createProject(named: prompt.suggestedName)
        } else {
            command.projectName = nil
        }
        return await create(command, now: now)
    }

    // MARK: - Cancel

    private func cancel(_ command: AssistantCommand, now: Date) async -> ExecutionOutcome {
        switch findTarget(command, now: now) {
        case .none:
            return .reply("I could not find an alarm matching that.")
        case .ambiguous(let choices):
            return .disambiguation(DisambiguationPrompt(
                command: command, choices: choices, reply: "Which one?"))
        case .unique(let candidate):
            guard let occurrence = store.occurrence(id: candidate.id) else {
                return .failure("That alarm is no longer in the store.")
            }
            // "Cancel the gym alarm" on a recurring item means the series. Naming a specific day or
            // time means only that one.
            let namedSpecificTime = command.targetAt != nil
            let wholeSeries = (occurrence.item?.recurrence.isRepeating ?? false) && !namedSpecificTime
            await cancelOccurrence(occurrence, wholeSeries: wholeSeries, reason: "Cancelled: \(command.originalText)")
            store.save("cancel")
            lastReferencedOccurrenceID = occurrence.id
            await review.reconcileReview(forDayKey: occurrence.dayKey, now: now)

            let scope = wholeSeries ? " and every repeat of it" : ""
            return .reply("Cancelled \(Phrasing.isolate(candidate.title))\(scope), was \(Phrasing.when(candidate.scheduledAt, now: now, calendar: calendar)).")
        }
    }

    private func cancelOccurrence(_ occurrence: AlarmOccurrence, wholeSeries: Bool, reason: String) async {
        let targets: [AlarmOccurrence]
        if wholeSeries, let item = occurrence.item {
            targets = item.occurrences.filter { $0.status == .scheduled }
            item.isCancelled = true
            item.cancelledAt = .now
            item.modifiedAt = .now
        } else {
            targets = [occurrence]
        }

        for target in targets {
            if let alarmKitID = target.alarmKitID {
                await scheduler.cancel(id: alarmKitID)
            }
            target.status = .cancelled
            target.isRegisteredWithAlarmKit = false
            store.logEvent(.occurrenceCancelled, reason, itemID: target.item?.id, occurrenceID: target.id)
        }
    }

    // MARK: - Postpone

    private func postpone(_ command: AssistantCommand, now: Date) async -> ExecutionOutcome {
        switch findTarget(command, now: now) {
        case .none:
            return .reply("I could not find which alarm to postpone.")
        case .ambiguous(let choices):
            return .disambiguation(DisambiguationPrompt(
                command: command, choices: choices, reply: "Postpone which one?"))
        case .unique(let candidate):
            guard var newDate = command.scheduledAt else {
                return .reply("Postpone \(Phrasing.isolate(candidate.title)) to when?")
            }
            // "Move the IBM thing to Friday" names a day but no time. Keep the time it already had
            // rather than dropping it on a default hour.
            if command.timeWasDefaulted {
                newDate = carryTimeOfDay(from: candidate.scheduledAt, onto: newDate)
            }
            guard let result = await reschedule(occurrenceID: candidate.id,
                                                to: newDate,
                                                now: now,
                                                reason: "Postponed: \(command.originalText)") else {
                return .failure("That alarm could not be moved.")
            }
            lastReferencedOccurrenceID = result
            return .reply("Moved \(Phrasing.isolate(candidate.title)) to \(Phrasing.when(newDate, now: now, calendar: calendar)). The original is kept in history as postponed.")
        }
    }

    /// Marks the old occurrence postponed, keeps the link in both directions, and creates a new one.
    /// The old row is never edited in place — requirement 9 wants the history readable afterwards.
    @discardableResult
    func reschedule(occurrenceID: UUID, to newDate: Date, now: Date = .now, reason: String) async -> UUID? {
        guard let old = store.occurrence(id: occurrenceID), let item = old.item else { return nil }

        if let alarmKitID = old.alarmKitID, old.status == .scheduled {
            await scheduler.cancel(id: alarmKitID)
        }

        let new = AlarmOccurrence(scheduledAt: newDate,
                                  dayKey: DayKey.make(for: newDate, calendar: calendar),
                                  item: item)
        new.postponedFromID = old.id
        store.context.insert(new)

        old.status = .postponed
        old.postponedToID = new.id
        old.isRegisteredWithAlarmKit = false

        let request = makeRequest(occurrence: new, item: item, mode: .fixed(newDate))
        _ = await register(request, on: new, itemID: item.id)

        store.logEvent(.occurrencePostponed,
                       "\(reason) → \(newDate)",
                       itemID: item.id, occurrenceID: old.id)
        item.modifiedAt = .now
        store.save("reschedule")

        await review.reconcileReview(forDayKey: old.dayKey, now: now)
        await review.reconcileReview(forDayKey: new.dayKey, now: now)
        return new.id
    }

    private func carryTimeOfDay(from source: Date, onto target: Date) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: source)
        let resolver = DateResolver(calendar: calendar)
        return resolver.compose(day: calendar.startOfDay(for: target),
                                hour: time.hour ?? 9,
                                minute: time.minute ?? 0)
    }

    // MARK: - Edit

    private func edit(_ command: AssistantCommand, now: Date) async -> ExecutionOutcome {
        guard command.scheduledAt != nil else {
            return .reply("What should I change it to?")
        }
        // An edit that moves the time is a postpone with the history preserved. Same operation.
        return await postpone(command, now: now)
    }

    /// Flips a guessed AM/PM. Behind the one-tap chip on the confirmation bubble.
    func flipMeridiem(occurrenceID: UUID, now: Date = .now) async -> ExecutionOutcome {
        guard let occurrence = store.occurrence(id: occurrenceID),
              let alternative = Phrasing.meridiemAlternative(for: occurrence.scheduledAt, calendar: calendar)
        else { return .failure("That alarm is gone.") }

        let title = occurrence.title
        guard await reschedule(occurrenceID: occurrenceID, to: alternative, now: now,
                               reason: "AM/PM corrected by hand") != nil else {
            return .failure("Could not move that alarm.")
        }
        return .reply("Moved \(Phrasing.isolate(title)) to \(Phrasing.when(alternative, now: now, calendar: calendar)).")
    }

    // MARK: - Status

    private func mark(_ command: AssistantCommand, as status: OccurrenceStatus, now: Date) async -> ExecutionOutcome {
        switch findTarget(command, now: now) {
        case .none:
            return .reply("I could not find that one.")
        case .ambiguous(let choices):
            return .disambiguation(DisambiguationPrompt(
                command: command, choices: choices, reply: "Which one?"))
        case .unique(let candidate):
            await setStatus(occurrenceID: candidate.id, to: status, now: now)
            let verb = status == .completed ? "Marked done" : "Marked missed"
            return .reply("\(verb): \(Phrasing.isolate(candidate.title)).")
        }
    }

    func setStatus(occurrenceID: UUID, to status: OccurrenceStatus, now: Date = .now) async {
        guard let occurrence = store.occurrence(id: occurrenceID) else { return }
        if occurrence.status == .scheduled, let alarmKitID = occurrence.alarmKitID, status.isHistorical {
            await scheduler.cancel(id: alarmKitID)
            occurrence.isRegisteredWithAlarmKit = false
        }
        occurrence.status = status
        let kind: EventKind = status == .completed ? .occurrenceCompleted : .occurrenceMissed
        store.logEvent(kind, "Marked \(status.rawValue).", itemID: occurrence.item?.id, occurrenceID: occurrence.id)
        store.save("set status")
        lastReferencedOccurrenceID = occurrenceID
    }

    // MARK: - Reads

    private func list(_ command: AssistantCommand, now: Date) -> ExecutionOutcome {
        var items = store.upcoming(from: now)
        var scope = "coming up"

        // "What alarms do I have tomorrow?" is not a postpone, so the parser files "tomorrow" as
        // the command's own time rather than as a target. Either field is a day filter here.
        if let targetAt = command.targetAt ?? command.scheduledAt {
            let dayKey = DayKey.make(for: targetAt, calendar: calendar)
            items = items.filter { $0.dayKey == dayKey }
            scope = "on " + Phrasing.when(targetAt, now: now, calendar: calendar)
                .replacingOccurrences(of: " at \(Phrasing.time(targetAt))", with: "")
        }

        guard !items.isEmpty else {
            return .list(ListResult(occurrenceIDs: [], reply: "Nothing \(scope)."))
        }
        let lines = items.prefix(12).map { occurrence in
            "· \(Phrasing.when(occurrence.scheduledAt, now: now, calendar: calendar)) — \(Phrasing.isolate(occurrence.title))"
        }
        return .list(ListResult(occurrenceIDs: items.map(\.id),
                                reply: lines.joined(separator: "\n")))
    }

    private func next(now: Date) -> ExecutionOutcome {
        let items = store.upcoming(from: now, limit: 3)
        guard !items.isEmpty else {
            return .list(ListResult(occurrenceIDs: [], reply: "Nothing scheduled."))
        }
        let lines = items.map { occurrence -> String in
            let project = occurrence.projectName
            let suffix = project == Constants.defaultProjectName ? "" : " · \(Phrasing.isolate(project))"
            return "· \(Phrasing.relative(occurrence.scheduledAt, now: now)) — \(Phrasing.isolate(occurrence.title))\(suffix)"
        }
        lastReferencedOccurrenceID = items.first?.id
        return .list(ListResult(occurrenceIDs: items.map(\.id), reply: lines.joined(separator: "\n")))
    }

    // MARK: - Notes

    private func note(_ command: AssistantCommand, now: Date) -> ExecutionOutcome {
        let dayKey = DayKey.make(for: now, calendar: calendar)
        let log = store.dailyLog(for: dayKey, calendar: calendar)
        let text = command.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        log.notes = log.notes.isEmpty ? text : log.notes + "\n" + text
        log.modifiedAt = now
        store.logEvent(.dailyNoteSaved, "Note added to \(dayKey).")
        store.save("note")
        return .reply("Noted.")
    }

    // MARK: - Target resolution

    func findTarget(_ command: AssistantCommand, now: Date) -> OccurrenceMatcher.Decision {
        let candidates = store.matchCandidates(now: now)
        guard !candidates.isEmpty else { return .none }

        // "Postpone that" with nothing else to go on means the last thing we talked about.
        let hasClue = (command.targetQuery?.isEmpty == false) || command.targetAt != nil
        if !hasClue {
            if let last = lastReferencedOccurrenceID,
               let match = candidates.first(where: { $0.id == last }) {
                return .unique(match)
            }
            if let soonest = candidates.filter({ $0.scheduledAt >= now })
                .min(by: { $0.scheduledAt < $1.scheduledAt }) {
                return .unique(soonest)
            }
            return .none
        }

        let ranked = OccurrenceMatcher.rank(candidates: candidates,
                                            query: command.targetQuery,
                                            targetAt: command.targetAt,
                                            targetHasClock: command.targetHasClock,
                                            now: now,
                                            calendar: calendar)
        return OccurrenceMatcher.decide(ranked)
    }

    func applyDisambiguation(_ prompt: DisambiguationPrompt,
                             choice: MatchCandidate,
                             now: Date = .now) async -> ExecutionOutcome {
        var command = prompt.command
        // Pin the choice so the matcher cannot wander on the second pass.
        command.targetQuery = choice.title
        command.targetAt = choice.scheduledAt
        command.targetHasClock = true
        lastReferencedOccurrenceID = choice.id

        switch command.action {
        case .cancelAlarm:
            guard let occurrence = store.occurrence(id: choice.id) else { return .failure("Gone.") }
            await cancelOccurrence(occurrence, wholeSeries: false, reason: "Cancelled by choice.")
            store.save("cancel chosen")
            await review.reconcileReview(forDayKey: occurrence.dayKey, now: now)
            return .reply("Cancelled \(Phrasing.isolate(choice.title)).")
        case .postponeAlarm, .editAlarm:
            guard var newDate = prompt.command.scheduledAt else {
                return .reply("Move \(Phrasing.isolate(choice.title)) to when?")
            }
            if prompt.command.timeWasDefaulted {
                newDate = carryTimeOfDay(from: choice.scheduledAt, onto: newDate)
            }
            guard await reschedule(occurrenceID: choice.id, to: newDate, now: now,
                                   reason: "Postponed by choice") != nil else {
                return .failure("Could not move that.")
            }
            return .reply("Moved \(Phrasing.isolate(choice.title)) to \(Phrasing.when(newDate, now: now, calendar: calendar)).")
        case .markCompleted:
            await setStatus(occurrenceID: choice.id, to: .completed, now: now)
            return .reply("Marked done: \(Phrasing.isolate(choice.title)).")
        case .markMissed:
            await setStatus(occurrenceID: choice.id, to: .missed, now: now)
            return .reply("Marked missed: \(Phrasing.isolate(choice.title)).")
        default:
            return .reply("Done.")
        }
    }

    // MARK: - Manual creation (fallback form)

    func createManually(title: String,
                        date: Date,
                        recurrence: RecurrenceRule,
                        projectName: String?,
                        originalText: String,
                        now: Date = .now) async -> ExecutionOutcome {
        var command = AssistantCommand()
        command.action = .createAlarm
        command.title = title
        command.scheduledAt = date
        command.recurrence = recurrence
        command.projectName = projectName
        command.originalText = originalText
        command.source = .manual
        command.confidence = 1.0
        return await create(command, now: now)
    }
}
