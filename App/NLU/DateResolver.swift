import Foundation

struct ResolvedTime: Equatable, Sendable {
    let date: Date
    /// True when the AM/PM half of the day was inferred rather than stated. Drives the one-tap
    /// correction chip on the confirmation bubble instead of a blocking question.
    let meridiemWasGuessed: Bool
    /// True when the request named a day but no time, so the default reminder hour was used.
    let timeWasDefaulted: Bool
    /// True when the requested wall-clock time had already passed and the date moved forward.
    let rolledForward: Bool
}

/// Turns a `TimeSpec` into an absolute instant using the phone's own calendar, locale and timezone.
///
/// Every date in this app comes from here. It is a plain struct with no dependencies so that the
/// awkward cases — DST, midnight, "at 7" said at 8pm — can be tested without a store or a device.
struct DateResolver {
    var calendar: Calendar
    var defaultReminderHour: Int

    init(calendar: Calendar = .current, defaultReminderHour: Int = 9) {
        self.calendar = calendar
        self.defaultReminderHour = defaultReminderHour
    }

    func resolve(_ spec: TimeSpec, now: Date = .now) -> ResolvedTime? {
        // A relative offset is absolute arithmetic on the instant — no day, no wall clock, no
        // meridiem question. "in 5 minutes" across a DST boundary is still 300 seconds.
        if let relative = spec.relative {
            guard let date = calendar.date(byAdding: relative.unit.calendarComponent,
                                           value: relative.value,
                                           to: now) else { return nil }
            return ResolvedTime(date: truncateToMinute(date),
                                meridiemWasGuessed: false,
                                timeWasDefaulted: false,
                                rolledForward: false)
        }

        guard !spec.isEmpty else { return nil }

        let (hour, minute, meridiemGuessed, timeDefaulted) = resolveWallClock(spec)
        let today = calendar.startOfDay(for: now)
        let baseDay = resolveBaseDay(spec.dayAnchor, today: today, now: now)

        var date = compose(day: baseDay, hour: hour, minute: minute)
        var rolled = false

        if date <= now {
            switch spec.dayAnchor {
            case .unspecified, .today:
                // "remind me at 7" said at 8pm means tomorrow at 7.
                if let next = calendar.date(byAdding: .day, value: 1, to: date) {
                    date = next
                    rolled = true
                }
            case .weekday:
                // "Friday at 11" said on Friday at 2pm means the Friday after this one.
                if let next = calendar.date(byAdding: .day, value: 7, to: date) {
                    date = next
                    rolled = true
                }
            case .explicit(let month, let day, let year) where year == nil:
                // A bare "on the 4th of March" that has passed means next year.
                if let next = calendar.date(byAdding: .year, value: 1, to: date) {
                    date = next
                    rolled = true
                }
                _ = (month, day)
            default:
                // The user named a specific past day. That is their call, not a parsing mistake —
                // it is how "I finished the thing from yesterday" gets matched.
                break
            }
        }

        return ResolvedTime(date: date,
                            meridiemWasGuessed: meridiemGuessed,
                            timeWasDefaulted: timeDefaulted,
                            rolledForward: rolled)
    }

    // MARK: - Wall clock

    private func resolveWallClock(_ spec: TimeSpec) -> (hour: Int, minute: Int, guessed: Bool, defaulted: Bool) {
        if let clock = spec.clock {
            let (hour, guessed) = Self.resolveHour(clock: clock, partOfDay: spec.partOfDay)
            return (hour, min(max(clock.minute, 0), 59), guessed, false)
        }
        if let part = spec.partOfDay {
            return (part.defaultHour, 0, false, false)
        }
        return (defaultReminderHour, 0, false, true)
    }

    /// The AM/PM decision, in one place so it can be tested directly.
    static func resolveHour(clock: ClockTime, partOfDay: PartOfDay?) -> (hour: Int, guessed: Bool) {
        let raw = clock.hour

        if let meridiem = clock.meridiem {
            return (apply(meridiem, to: raw), false)
        }
        if let part = partOfDay, let implied = part.impliedMeridiem(forHour: raw) {
            return (apply(implied, to: raw), false)
        }
        // 0, and 13–23, are already 24-hour notation. Nothing to guess.
        if raw == 0 || raw > 12 { return (min(raw, 23), false) }
        // "at 12" is lunchtime, not midnight.
        if raw == 12 { return (12, false) }

        // Bare 1–11. Documented in ARCHITECTURE.md §8: 1–6 read as afternoon, 7–11 as morning.
        // The user gets a one-tap correction rather than a question every single time.
        return (raw <= 6 ? raw + 12 : raw, true)
    }

    static func apply(_ meridiem: Meridiem, to hour: Int) -> Int {
        switch meridiem {
        case .am:
            return hour == 12 ? 0 : min(hour, 23)
        case .pm:
            if hour == 12 { return 12 }
            return hour < 12 ? hour + 12 : min(hour, 23)
        }
    }

    // MARK: - Base day

    private func resolveBaseDay(_ anchor: DayAnchor, today: Date, now: Date) -> Date {
        switch anchor {
        case .unspecified, .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .dayAfterTomorrow:
            return calendar.date(byAdding: .day, value: 2, to: today) ?? today
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case .inDays(let n):
            return calendar.date(byAdding: .day, value: n, to: today) ?? today
        case .weekday(let weekday, let qualifier):
            return day(forWeekday: weekday, qualifier: qualifier, today: today)
        case .explicit(let month, let day, let year):
            var comps = DateComponents()
            comps.year = year ?? calendar.component(.year, from: today)
            comps.month = month
            comps.day = day
            return calendar.date(from: comps).map { calendar.startOfDay(for: $0) } ?? today
        }
    }

    private func day(forWeekday weekday: Int, qualifier: WeekdayQualifier, today: Date) -> Date {
        let current = calendar.component(.weekday, from: today)
        var delta = (weekday - current + 7) % 7
        if qualifier == .next && delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }

    // MARK: - Composition

    /// Builds an instant from a day plus a wall clock.
    ///
    /// On a spring-forward day the requested wall-clock time may not exist. Foundation resolves
    /// that to the first valid instant after the gap, which is the behaviour an alarm wants —
    /// it fires once, slightly late, rather than not at all.
    func compose(day: Date, hour: Int, minute: Int) -> Date {
        var comps = calendar.dateComponents([.era, .year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.nanosecond = 0
        if let date = calendar.date(from: comps) { return date }
        return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    private func truncateToMinute(_ date: Date) -> Date {
        var comps = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        comps.nanosecond = 0
        return calendar.date(from: comps) ?? date
    }
}
