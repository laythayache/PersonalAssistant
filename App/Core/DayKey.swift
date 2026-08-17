import Foundation

/// "yyyy-MM-dd" in the user's own calendar and timezone.
///
/// Deliberately not `ISO8601DateFormatter`: that is UTC, and an alarm at 00:30 Beirut would then be
/// filed under the previous day and disappear from that evening's review.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func make(for date: Date, calendar: Calendar = .current) -> String {
        let f = formatter
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    static func startOfDay(for key: String, calendar: Calendar = .current) -> Date? {
        let f = formatter
        f.timeZone = calendar.timeZone
        guard let date = f.date(from: key) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func today(calendar: Calendar = .current, now: Date = .now) -> String {
        make(for: now, calendar: calendar)
    }
}
