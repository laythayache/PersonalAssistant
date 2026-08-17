import Foundation

/// What the parser extracted about *when*, before any calendar arithmetic happens.
///
/// This is the hand-off boundary between "understanding language" and "computing a date".
/// Both the rules layer and Apple's on-device model produce one of these; neither is ever allowed
/// to produce a `Date` directly (requirement 16).
struct TimeSpec: Equatable, Sendable {
    var dayAnchor: DayAnchor = .unspecified
    var clock: ClockTime?
    var partOfDay: PartOfDay?
    var relative: RelativeOffset?

    var isEmpty: Bool {
        dayAnchor == .unspecified && clock == nil && partOfDay == nil && relative == nil
    }
}

enum DayAnchor: Equatable, Sendable {
    case unspecified
    case today
    case tomorrow
    case dayAfterTomorrow
    case yesterday
    /// `Calendar` weekday numbers, 1 = Sunday.
    case weekday(Int, WeekdayQualifier)
    case inDays(Int)
    case explicit(month: Int, day: Int, year: Int?)
}

enum WeekdayQualifier: Sendable, Equatable {
    /// "on Friday" / "this Friday" — the first Friday from today onwards.
    case soonest
    /// "next Friday" — never today.
    case next
}

enum Meridiem: String, Sendable, Equatable {
    case am
    case pm
}

struct ClockTime: Equatable, Sendable {
    var hour: Int
    var minute: Int
    var meridiem: Meridiem?

    init(hour: Int, minute: Int = 0, meridiem: Meridiem? = nil) {
        self.hour = hour
        self.minute = minute
        self.meridiem = meridiem
    }
}

enum PartOfDay: String, Sendable, Equatable {
    case morning
    case noon
    case afternoon
    case evening
    case night
    case midnight

    /// Used when a part of day is given with no clock time at all ("postpone until tomorrow afternoon").
    var defaultHour: Int {
        switch self {
        case .morning: return 8
        case .noon: return 12
        case .afternoon: return 15
        case .evening: return 19
        case .night: return 21
        case .midnight: return 0
        }
    }

    /// Which half of the day this word forces a bare hour into.
    /// "3 at night" is 3 AM; "9 at night" is 9 PM — hence the hour-dependent answer.
    func impliedMeridiem(forHour hour: Int) -> Meridiem? {
        switch self {
        case .morning: return .am
        case .noon, .afternoon, .evening: return .pm
        case .night: return hour >= 6 ? .pm : .am
        case .midnight: return .am
        }
    }
}

struct RelativeOffset: Equatable, Sendable {
    var unit: OffsetUnit
    var value: Int
}

enum OffsetUnit: String, Sendable, Equatable {
    case minute
    case hour
    case day
    case week
    case month
    case year

    var calendarComponent: Calendar.Component {
        switch self {
        case .minute: return .minute
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}
