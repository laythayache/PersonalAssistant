import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Layer 2: Apple's on-device model, used only for the messages the rules layer could not read.
///
/// Two hard rules apply here:
/// 1. It extracts **slots**, never dates. The same `DateResolver` the rules layer uses turns those
///    slots into an instant, so the model cannot hallucinate a timestamp (requirement 16).
/// 2. It is never asked to read a language Apple does not claim to support. That check is made at
///    runtime against `supportedLanguages`, so Arabic starts flowing through here automatically on
///    the day Apple adds it — and produces a graceful fallback until then.
@MainActor
final class FoundationModelInterpreter {

    enum Availability: Equatable {
        case ready
        case unsupportedLanguage
        case modelUnavailable(String)
        case frameworkMissing
    }

    private let calendar: Calendar
    private let defaultReminderHour: Int

    init(calendar: Calendar = .current, defaultReminderHour: Int = 9) {
        self.calendar = calendar
        self.defaultReminderHour = defaultReminderHour
    }

    // MARK: - Availability

    var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                return .modelUnavailable(String(describing: reason))
            @unknown default:
                return .modelUnavailable("unknown")
            }
        }
        return .frameworkMissing
        #else
        return .frameworkMissing
        #endif
    }

    /// Whether Apple's model claims to support the language this text is written in.
    ///
    /// Arabic script is checked against the model's own list rather than hard-coded, and Arabizi is
    /// refused outright: it is romanised Arabic, so a model that has not been trained on Arabic
    /// will read "bokra" as an English word and produce a confidently wrong answer.
    func canHandle(_ normalized: NormalizedText) -> Bool {
        guard availability == .ready else { return false }
        if Normalizer.looksLikeArabizi(normalized) { return false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let supported = SystemLanguageModel.default.supportedLanguages
            switch normalized.script {
            case .arabic, .mixed:
                return supported.contains(Locale.Language(identifier: "ar"))
            case .latin, .unknown:
                let current = Locale.current.language
                return supported.contains(current) || supported.contains(Locale.Language(identifier: "en"))
            }
        }
        #endif
        return false
    }

    // MARK: - Interpretation

    func interpret(_ text: String, normalized: NormalizedText, now: Date = .now) async -> AssistantCommand? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard canHandle(normalized) else { return nil }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                var options = GenerationOptions(sampling: .greedy)
                options.temperature = 0
                let response = try await session.respond(to: text,
                                                         generating: ExtractedSlots.self,
                                                         options: options)
                return build(from: response.content, originalText: text, normalized: normalized, now: now)
            } catch {
                DebugLog.shared.error("nlu", "Foundation model failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static var instructions: String {
        """
        You convert a personal assistant request into structured slots.

        Rules you must follow:
        - Never compute or output a date. Only report what the user literally named.
        - If the user did not name something, leave that slot at its "unspecified"/zero value.
        - Only set isAM or isPM when the user actually said morning/evening/am/pm. Do not guess.
        - Put the subject in the user's own words. Do not rephrase, translate, or add words.
        - "Remind me" and "set an alarm" are the same action: createAlarm.
        """
    }
    #endif

    // MARK: - Slot schema

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    enum SlotAction: String, Equatable {
        case createAlarm
        case cancelAlarm
        case postponeAlarm
        case editAlarm
        case listAlarms
        case markCompleted
        case markMissed
        case whatsNext
        case note
    }

    @available(iOS 26.0, *)
    @Generable
    enum SlotDay: String, Equatable {
        case unspecified
        case today
        case tonight
        case tomorrow
        case dayAfterTomorrow
        case yesterday
        case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    }

    @available(iOS 26.0, *)
    @Generable
    enum SlotPartOfDay: String, Equatable {
        case unspecified, morning, noon, afternoon, evening, night, midnight
    }

    @available(iOS 26.0, *)
    @Generable
    enum SlotUnit: String, Equatable {
        case none, minute, hour, day, week, month, year
    }

    @available(iOS 26.0, *)
    @Generable
    enum SlotRecurrence: String, Equatable {
        case none, daily, weekdays, weekends, weeklyOnDays, everyNDays, monthly, yearly
    }

    @available(iOS 26.0, *)
    @Generable
    struct ExtractedSlots: Equatable {
        @Guide(description: "What the user is asking the app to do.")
        var action: SlotAction

        @Guide(description: "What the reminder is about, in the user's own words. Empty string if not stated.")
        var subject: String

        @Guide(description: "The day the user named, or unspecified.")
        var day: SlotDay

        @Guide(description: "The hour the user said, as they said it. 0 when no time was given.")
        var hour: Int

        @Guide(description: "Minutes past the hour. 0 when not stated.")
        var minute: Int

        @Guide(description: "True only if the user explicitly said pm, evening or night.")
        var isPM: Bool

        @Guide(description: "True only if the user explicitly said am or morning.")
        var isAM: Bool

        @Guide(description: "Part of the day the user named, or unspecified.")
        var partOfDay: SlotPartOfDay

        @Guide(description: "For 'in N minutes/hours/days', the N. 0 when not used.")
        var relativeValue: Int

        @Guide(description: "The unit that goes with relativeValue, or none.")
        var relativeUnit: SlotUnit

        @Guide(description: "How the alarm repeats.")
        var recurrence: SlotRecurrence

        @Guide(description: "For weeklyOnDays, which weekdays. Empty otherwise.")
        var recurrenceDays: [SlotDay]

        @Guide(description: "For everyNDays, the N. 0 otherwise.")
        var recurrenceInterval: Int

        @Guide(description: "For cancel, postpone or edit: which existing alarm the user means, in their words. Empty otherwise.")
        var target: String
    }

    // MARK: - Slots to command

    @available(iOS 26.0, *)
    private func build(from slots: ExtractedSlots,
                       originalText: String,
                       normalized: NormalizedText,
                       now: Date) -> AssistantCommand {
        var command = AssistantCommand()
        command.originalText = originalText
        command.detectedScript = normalized.script.rawValue
        command.source = .foundationModel
        command.action = Self.action(for: slots.action)

        var spec = TimeSpec()
        spec.dayAnchor = Self.anchor(for: slots.day)
        if slots.day == .tonight { spec.partOfDay = .evening }

        if slots.hour > 0 || slots.minute > 0 {
            var meridiem: Meridiem?
            if slots.isPM { meridiem = .pm }
            if slots.isAM { meridiem = .am }
            spec.clock = ClockTime(hour: min(max(slots.hour, 0), 23),
                                   minute: min(max(slots.minute, 0), 59),
                                   meridiem: meridiem)
        }
        if let part = Self.partOfDay(for: slots.partOfDay), spec.partOfDay == nil {
            spec.partOfDay = part
        }
        if slots.relativeValue > 0, let unit = Self.unit(for: slots.relativeUnit) {
            spec.relative = RelativeOffset(unit: unit, value: slots.relativeValue)
        }

        let resolver = DateResolver(calendar: calendar, defaultReminderHour: defaultReminderHour)
        var recurrence = Self.recurrence(for: slots, calendar: calendar)

        if case .weekly(let days) = recurrence, spec.dayAnchor == .unspecified, !days.isEmpty {
            var soonest: (day: Int, date: Date)?
            for day in days.sorted() {
                var probe = spec
                probe.dayAnchor = .weekday(day, .soonest)
                if let resolved = resolver.resolve(probe, now: now),
                   soonest == nil || resolved.date < soonest!.date {
                    soonest = (day, resolved.date)
                }
            }
            if let soonest { spec.dayAnchor = .weekday(soonest.day, .soonest) }
        }

        if let resolved = resolver.resolve(spec, now: now) {
            command.scheduledAt = resolved.date
            command.meridiemWasGuessed = resolved.meridiemWasGuessed
            command.timeWasDefaulted = resolved.timeWasDefaulted
            command.rolledForward = resolved.rolledForward
            if slots.recurrence == .monthly {
                recurrence = .monthlyOnDay(calendar.component(.day, from: resolved.date))
            }
        }
        command.recurrence = recurrence

        let subject = slots.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = slots.target.trimmingCharacters(in: .whitespacesAndNewlines)

        switch command.action {
        case .cancelAlarm, .postponeAlarm, .editAlarm, .markCompleted, .markMissed:
            command.targetQuery = target.isEmpty ? (subject.isEmpty ? nil : subject) : target
            command.title = command.targetQuery ?? ""
        case .saveNote:
            command.title = originalText
        default:
            command.title = subject
        }

        // The model is trusted less than the grammar, and only ever consulted when the grammar was
        // already unsure. A confident-sounding model answer still has to clear the same bar.
        var confidence = 0.55
        if command.scheduledAt != nil { confidence += 0.2 }
        if !command.title.isEmpty { confidence += 0.15 }
        command.confidence = min(confidence, 0.9)
        return command
    }

    @available(iOS 26.0, *)
    private static func action(for slot: SlotAction) -> AssistantAction {
        switch slot {
        case .createAlarm: return .createAlarm
        case .cancelAlarm: return .cancelAlarm
        case .postponeAlarm: return .postponeAlarm
        case .editAlarm: return .editAlarm
        case .listAlarms: return .listAlarms
        case .markCompleted: return .markCompleted
        case .markMissed: return .markMissed
        case .whatsNext: return .getNextItems
        case .note: return .saveNote
        }
    }

    @available(iOS 26.0, *)
    private static func anchor(for slot: SlotDay) -> DayAnchor {
        switch slot {
        case .unspecified: return .unspecified
        case .today, .tonight: return .today
        case .tomorrow: return .tomorrow
        case .dayAfterTomorrow: return .dayAfterTomorrow
        case .yesterday: return .yesterday
        case .sunday: return .weekday(1, .soonest)
        case .monday: return .weekday(2, .soonest)
        case .tuesday: return .weekday(3, .soonest)
        case .wednesday: return .weekday(4, .soonest)
        case .thursday: return .weekday(5, .soonest)
        case .friday: return .weekday(6, .soonest)
        case .saturday: return .weekday(7, .soonest)
        }
    }

    @available(iOS 26.0, *)
    private static func weekdayNumber(for slot: SlotDay) -> Int? {
        switch slot {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        default: return nil
        }
    }

    @available(iOS 26.0, *)
    private static func partOfDay(for slot: SlotPartOfDay) -> PartOfDay? {
        switch slot {
        case .unspecified: return nil
        case .morning: return .morning
        case .noon: return .noon
        case .afternoon: return .afternoon
        case .evening: return .evening
        case .night: return .night
        case .midnight: return .midnight
        }
    }

    @available(iOS 26.0, *)
    private static func unit(for slot: SlotUnit) -> OffsetUnit? {
        switch slot {
        case .none: return nil
        case .minute: return .minute
        case .hour: return .hour
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        }
    }

    @available(iOS 26.0, *)
    private static func recurrence(for slots: ExtractedSlots, calendar: Calendar) -> RecurrenceRule {
        switch slots.recurrence {
        case .none:
            return .none
        case .daily:
            return .weekly(days: RecurrenceRule.allDaysOfWeek)
        case .weekdays:
            return .weekly(days: RecurrenceRule.allWeekdays)
        case .weekends:
            return .weekly(days: [1, 7])
        case .weeklyOnDays:
            let days = Set(slots.recurrenceDays.compactMap(weekdayNumber(for:)))
            return days.isEmpty ? .none : .weekly(days: days)
        case .everyNDays:
            let interval = max(slots.recurrenceInterval, 1)
            return interval == 1 ? .weekly(days: RecurrenceRule.allDaysOfWeek) : .everyNDays(interval)
        case .monthly:
            return .monthlyOnDay(1)   // replaced once the first occurrence is known
        case .yearly:
            return .yearly
        }
    }
    #endif
}
