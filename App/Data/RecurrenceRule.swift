import Foundation

/// How an item repeats.
///
/// AlarmKit only understands one of these natively: `.weekly`. Everything else is expanded by
/// `RecurrenceEngine` into a rolling window of individual fixed alarms. See ARCHITECTURE.md §2.
enum RecurrenceRule: Codable, Equatable, Hashable, Sendable {
    case none
    /// `Calendar` weekday numbers: 1 = Sunday ... 7 = Saturday.
    case weekly(days: Set<Int>)
    case everyNDays(Int)
    case monthlyOnDay(Int)
    case yearly

    var isRepeating: Bool { self != .none }

    /// `.weekly` maps onto `Alarm.Schedule.Relative.Recurrence.weekly`, so the system keeps
    /// repeating it forever with no help from us. Everything else needs the rolling window.
    var isNativelySupportedByAlarmKit: Bool {
        if case .weekly = self { return true }
        return false
    }

    static let allWeekdays: Set<Int> = [2, 3, 4, 5, 6]      // Mon–Fri
    static let allDaysOfWeek: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    var describedBriefly: String {
        switch self {
        case .none:
            return "once"
        case .weekly(let days):
            if days == Self.allDaysOfWeek { return "every day" }
            if days == Self.allWeekdays { return "every weekday" }
            if days == [1, 7] { return "every weekend" }
            let names = days.sorted().map { Self.weekdayName($0) }
            return "every " + names.joined(separator: ", ")
        case .everyNDays(let n):
            return n == 1 ? "every day" : (n == 7 ? "every week" : "every \(n) days")
        case .monthlyOnDay(let d):
            return "monthly on day \(d)"
        case .yearly:
            return "every year"
        }
    }

    static func weekdayName(_ weekday: Int, short: Bool = false) -> String {
        let symbols = short
            ? Calendar(identifier: .gregorian).shortWeekdaySymbols
            : Calendar(identifier: .gregorian).weekdaySymbols
        guard (1...7).contains(weekday) else { return "?" }
        return symbols[weekday - 1]
    }

    // MARK: - JSON round trip, for the `String` column on AlarmItem

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ string: String?) -> RecurrenceRule {
        guard let string, let data = string.data(using: .utf8),
              let rule = try? JSONDecoder().decode(RecurrenceRule.self, from: data)
        else { return .none }
        return rule
    }
}
