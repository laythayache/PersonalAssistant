import Testing
import Foundation
@testable import PersonalAssistant

@Suite("Recurrence expansion")
struct RecurrenceEngineTests {

    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: Fixture.calendar) }

    @Test("Only weekly is handed to AlarmKit as a repeating schedule")
    func nativeSupport() {
        #expect(RecurrenceRule.weekly(days: [2]).isNativelySupportedByAlarmKit)
        #expect(RecurrenceRule.weekly(days: RecurrenceRule.allDaysOfWeek).isNativelySupportedByAlarmKit)
        #expect(!RecurrenceRule.everyNDays(3).isNativelySupportedByAlarmKit)
        #expect(!RecurrenceRule.monthlyOnDay(4).isNativelySupportedByAlarmKit)
        #expect(!RecurrenceRule.yearly.isNativelySupportedByAlarmKit)
        #expect(!RecurrenceRule.none.isNativelySupportedByAlarmKit)
    }

    @Test("A weekly rule schedules one alarm; the system repeats it")
    func weeklySchedulesOnce() {
        let anchor = Fixture.at(2026, 8, 24, 9, 0)
        let dates = engine.schedulableDates(rule: .weekly(days: [2]), anchor: anchor, now: Fixture.now)
        #expect(dates == [anchor])
    }

    @Test("Every 3 days pre-schedules a rolling window instead")
    func everyThreeDaysRolls() {
        let anchor = Fixture.at(2026, 8, 20, 9, 0)
        let dates = engine.schedulableDates(rule: .everyNDays(3), anchor: anchor, now: Fixture.now)

        #expect(dates.count == Constants.rollingHorizonCount)
        #expect(dates.first == anchor)
        for (index, date) in dates.enumerated() {
            let expected = Fixture.calendar.date(byAdding: .day, value: index * 3, to: anchor)
            #expect(date == expected, "step \(index) is off")
        }
        // 8 steps of 3 days is 21 days of unattended coverage before the app must be opened.
        let span = Fixture.calendar.dateComponents([.day], from: anchor, to: dates.last!).day
        #expect(span == 21)
    }

    @Test("A weekly rule with several days walks to the nearest one each time")
    func multiDayWeekly() throws {
        let anchor = Fixture.at(2026, 8, 20, 7, 0)            // Thursday
        let rule = RecurrenceRule.weekly(days: RecurrenceRule.allWeekdays)

        let friday = try #require(engine.advance(anchor, by: rule))
        #expect(Fixture.calendar.component(.weekday, from: friday) == 6)

        let monday = try #require(engine.advance(friday, by: rule))
        #expect(Fixture.calendar.component(.weekday, from: monday) == 2,
                "Saturday and Sunday are skipped")
    }

    @Test("A monthly rule clamps rather than sliding into the next month")
    func monthlyClamps() throws {
        // The 31st of March, repeated monthly, has to become the 30th of April — not the 1st of May.
        let anchor = Fixture.at(2026, 3, 31, 9, 0)
        let next = try #require(engine.advance(anchor, by: .monthlyOnDay(31)))
        let parts = Fixture.parts(next)
        #expect(parts.month == 4)
        #expect(parts.day == 30)
        #expect(parts.hour == 9)
    }

    @Test("A chain that was left unattended resumes in the future, not in the past")
    func staleChainSkipsForward() {
        // A three-day chain anchored a month ago must not fire ten alarms at once on reopening.
        let anchor = Fixture.at(2026, 7, 1, 9, 0)
        let dates = engine.rollingDates(rule: .everyNDays(3), anchor: anchor, now: Fixture.now, count: 3)
        #expect(dates.count == 3)
        #expect(dates.allSatisfy { $0 > Fixture.now })
    }

    @Test("A non-repeating rule produces exactly one date")
    func noneProducesOne() {
        let anchor = Fixture.at(2026, 8, 20, 9, 0)
        #expect(engine.schedulableDates(rule: .none, anchor: anchor, now: Fixture.now) == [anchor])
        #expect(engine.advance(anchor, by: .none) == nil)
    }
}
