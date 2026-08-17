import Foundation
import SwiftData
@testable import PersonalAssistant

/// A fixed calendar and a fixed "now" so that every assertion below is about the parser, not about
/// what day it happens to be when the suite runs.
enum Fixture {

    /// Beirut, because that is where the daylight-saving and midnight edge cases actually bite.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Beirut") ?? TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let date = calendar.date(from: components) else {
            fatalError("Fixture date \(year)-\(month)-\(day) \(hour):\(minute) is not representable")
        }
        return date
    }

    /// Wednesday, 19 August 2026, 10:00 in Beirut.
    static let now = at(2026, 8, 19, 10, 0)

    static let thursday = at(2026, 8, 20)     // tomorrow
    static let friday = at(2026, 8, 21)
    static let monday = at(2026, 8, 24)

    static func parser(defaultReminderHour: Int = 9) -> RuleParser {
        RuleParser(calendar: calendar, defaultReminderHour: defaultReminderHour)
    }

    static func resolver(defaultReminderHour: Int = 9) -> DateResolver {
        DateResolver(calendar: calendar, defaultReminderHour: defaultReminderHour)
    }

    static func parse(_ text: String, defaultReminderHour: Int = 9) -> AssistantCommand {
        parser(defaultReminderHour: defaultReminderHour).parse(text, now: now)
    }

    static func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    /// A live store on an in-memory container, plus a fake system alarm clock.
    @MainActor
    static func makeEnvironment() throws -> (store: Store, scheduler: InMemoryAlarmScheduler, executor: CommandExecutor, reconciler: Reconciler, review: DailyReviewService) {
        let container = try PersistenceController.makeEphemeralContainer()
        let store = Store(context: ModelContext(container))
        let scheduler = InMemoryAlarmScheduler()
        let review = DailyReviewService(store: store, scheduler: scheduler, calendar: calendar)
        let executor = CommandExecutor(store: store, scheduler: scheduler, review: review, calendar: calendar)
        let reconciler = Reconciler(store: store, scheduler: scheduler, review: review, calendar: calendar)
        return (store, scheduler, executor, reconciler, review)
    }
}
