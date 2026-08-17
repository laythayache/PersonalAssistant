import Foundation

/// The typed action layer from requirement 15. Generated prose never touches application state —
/// it becomes one of these, the app validates it, and the app performs the persistence and the
/// AlarmKit call.
enum AssistantAction: String, Codable, Sendable, CaseIterable {
    case createAlarm
    case cancelAlarm
    case postponeAlarm
    case editAlarm
    case listAlarms
    case markCompleted
    case markMissed
    case createProject
    case assignProject
    case getNextItems
    case addDailyNote
    /// Nothing actionable was found. The text is kept verbatim as a note — requirement 17.
    case saveNote
}

struct AssistantCommand: Codable, Equatable, Sendable {
    var action: AssistantAction = .saveNote
    /// What the alarm will be called. Built from the user's own words, never paraphrased.
    var title: String = ""
    var scheduledAt: Date?
    var recurrence: RecurrenceRule = .none
    var projectName: String?

    // Which existing item a cancel / postpone / edit is aimed at.
    var targetQuery: String?
    /// A time mentioned in the request that describes the *existing* item rather than the new one.
    var targetAt: Date?
    /// True when `targetAt` carried a clock time, so matching should be to the minute rather than
    /// to the whole day.
    var targetHasClock: Bool = false

    var meridiemWasGuessed: Bool = false
    var timeWasDefaulted: Bool = false
    var rolledForward: Bool = false

    var confidence: Double = 0
    var source: InterpreterSource = .rules
    /// Exactly what was typed. Carried all the way into the stored item.
    var originalText: String = ""
    var detectedScript: String = TextScript.unknown.rawValue

    /// Set only when executing the command as understood could plausibly create the wrong alarm.
    var clarificationNeeded: String?

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    static func fromJSON(_ string: String) -> AssistantCommand? {
        guard let data = string.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AssistantCommand.self, from: data)
    }

    /// Whether this command changes stored state, as opposed to only reading it.
    var isMutating: Bool {
        switch action {
        case .listAlarms, .getNextItems: return false
        default: return true
        }
    }
}
