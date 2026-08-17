import Foundation

/// Expands a `RecurrenceRule` into concrete fire times.
///
/// Only `.weekly` is handed to AlarmKit as a repeating schedule. Everything else is expanded here
/// into individual fixed alarms — `Constants.rollingHorizonCount` of them at a time — because
/// AlarmKit's recurrence has exactly two cases and neither of them is "every 3 days".
struct RecurrenceEngine {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The fire times to register right now for an item starting at `anchor`.
    ///
    /// - For `.none` this is the single anchor date.
    /// - For `.weekly` this is just the anchor: the system takes over the repeating from there.
    /// - For everything else this is the rolling window.
    func schedulableDates(rule: RecurrenceRule, anchor: Date, now: Date = .now, horizon: Int = Constants.rollingHorizonCount) -> [Date] {
        switch rule {
        case .none:
            return [anchor]
        case .weekly:
            return [anchor]
        case .everyNDays, .monthlyOnDay, .yearly:
            return rollingDates(rule: rule, anchor: anchor, now: now, count: horizon)
        }
    }

    /// The next `count` fire times at or after `anchor`, skipping any that are already in the past.
    func rollingDates(rule: RecurrenceRule, anchor: Date, now: Date = .now, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        var dates: [Date] = []
        var cursor = anchor
        var guardRail = 0

        // Fast-forward past anything already gone, so a chain that was not topped up for a while
        // resumes in the future rather than firing a burst of historical alarms.
        while cursor <= now, let next = advance(cursor, by: rule) {
            cursor = next
            guardRail += 1
            if guardRail > 1000 { return [] }
        }

        while dates.count < count {
            dates.append(cursor)
            guard let next = advance(cursor, by: rule) else { break }
            cursor = next
        }
        return dates
    }

    /// One step forward. Uses calendar arithmetic rather than adding seconds, so a daily alarm at
    /// 07:00 stays at 07:00 across a daylight-saving change instead of drifting to 06:00 or 08:00.
    func advance(_ date: Date, by rule: RecurrenceRule) -> Date? {
        switch rule {
        case .none:
            return nil
        case .weekly(let days):
            return nextWeekly(after: date, days: days)
        case .everyNDays(let n):
            return calendar.date(byAdding: .day, value: max(n, 1), to: date)
        case .monthlyOnDay(let day):
            return nextMonthly(after: date, dayOfMonth: day)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
    }

    private func nextWeekly(after date: Date, days: Set<Int>) -> Date? {
        guard !days.isEmpty else { return nil }
        for offset in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            if days.contains(calendar.component(.weekday, from: candidate)) { return candidate }
        }
        return nil
    }

    /// Keeps the requested day of month, clamping to the last day for months that are too short —
    /// "the 31st" becomes the 30th in April rather than silently sliding into May.
    private func nextMonthly(after date: Date, dayOfMonth: Int) -> Date? {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) else { return nil }
        guard let range = calendar.range(of: .day, in: .month, for: nextMonth) else { return nextMonth }

        var comps = calendar.dateComponents([.era, .year, .month, .hour, .minute, .second], from: nextMonth)
        comps.day = min(max(dayOfMonth, 1), range.upperBound - 1)
        return calendar.date(from: comps)
    }

    /// The wall-clock time an item repeats at, for handing to a native weekly AlarmKit schedule.
    func timeComponents(of date: Date) -> (hour: Int, minute: Int) {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0, comps.minute ?? 0)
    }
}
