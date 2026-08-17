import Testing
import Foundation
@testable import PersonalAssistant

/// Requirement 16. These are the cases that quietly produce an alarm at the wrong hour, which is
/// worse than no alarm at all because you do not find out until you have missed something.
@Suite("Dates and times")
struct DateResolverTests {

    // MARK: - The AM/PM decision

    @Test("A bare hour picks the half of the day a person means")
    func bareHourHeuristic() {
        func hour(_ value: Int) -> Int {
            DateResolver.resolveHour(clock: ClockTime(hour: value), partOfDay: nil).hour
        }
        #expect(hour(1) == 13)
        #expect(hour(4) == 16)
        #expect(hour(6) == 18)
        #expect(hour(7) == 7)
        #expect(hour(11) == 11)
        #expect(hour(12) == 12, "'at 12' is lunchtime, not midnight")
        #expect(hour(0) == 0)
        #expect(hour(19) == 19, "24-hour input is left alone")
    }

    @Test("An explicit meridiem is never second-guessed")
    func explicitMeridiemWins() {
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 4, meridiem: .am), partOfDay: nil).hour == 4)
        #expect(!DateResolver.resolveHour(clock: ClockTime(hour: 4, meridiem: .am), partOfDay: nil).guessed)
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 12, meridiem: .am), partOfDay: nil).hour == 0)
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 12, meridiem: .pm), partOfDay: nil).hour == 12)
    }

    @Test("'at night' means different halves for 3 and for 9")
    func nightIsHourDependent() {
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 3), partOfDay: .night).hour == 3)
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 9), partOfDay: .night).hour == 21)
    }

    @Test("A guessed hour is flagged so the app can offer a correction")
    func guessIsReported() {
        #expect(DateResolver.resolveHour(clock: ClockTime(hour: 4), partOfDay: nil).guessed)
        #expect(!DateResolver.resolveHour(clock: ClockTime(hour: 4), partOfDay: .morning).guessed)
        #expect(!DateResolver.resolveHour(clock: ClockTime(hour: 16), partOfDay: nil).guessed)
    }

    // MARK: - Rolling forward

    @Test("A time that has already passed today moves to tomorrow")
    func passedTimeRollsForward() throws {
        var spec = TimeSpec()
        spec.clock = ClockTime(hour: 7)                      // 07:00, and it is already 10:00
        let resolved = try #require(Fixture.resolver().resolve(spec, now: Fixture.now))
        #expect(Fixture.parts(resolved.date).day == 20)
        #expect(Fixture.parts(resolved.date).hour == 7)
        #expect(resolved.rolledForward)
    }

    @Test("A named weekday that has passed today moves a whole week")
    func passedWeekdayRollsAWeek() throws {
        var spec = TimeSpec()
        spec.dayAnchor = .weekday(4, .soonest)               // Wednesday — today
        spec.clock = ClockTime(hour: 8)                      // 08:00, already gone
        let resolved = try #require(Fixture.resolver().resolve(spec, now: Fixture.now))
        #expect(Fixture.parts(resolved.date).day == 26, "the following Wednesday, not this evening")
        #expect(Fixture.parts(resolved.date).weekday == 4)
    }

    @Test("'next Friday' is never today")
    func nextQualifierSkipsToday() throws {
        var spec = TimeSpec()
        spec.dayAnchor = .weekday(4, .next)                  // Wednesday, qualified "next"
        spec.clock = ClockTime(hour: 18)                     // still ahead of 10:00 today
        let resolved = try #require(Fixture.resolver().resolve(spec, now: Fixture.now))
        #expect(Fixture.parts(resolved.date).day == 26)
    }

    // MARK: - Midnight

    @Test("Midnight lands on the following day, not the one just gone")
    func midnightGoesForward() throws {
        var spec = TimeSpec()
        spec.partOfDay = .midnight
        let resolved = try #require(Fixture.resolver().resolve(spec, now: Fixture.now))
        #expect(Fixture.parts(resolved.date).hour == 0)
        #expect(Fixture.parts(resolved.date).day == 20)
    }

    @Test("A day key uses the phone's own timezone, not UTC")
    func dayKeyIsLocal() {
        // 00:30 in Beirut is still the previous day in UTC. Filing it under the UTC day would drop
        // it out of the right evening's review.
        let justAfterMidnight = Fixture.at(2026, 8, 20, 0, 30)
        #expect(DayKey.make(for: justAfterMidnight, calendar: Fixture.calendar) == "2026-08-20")
    }

    // MARK: - Relative offsets

    @Test("A relative offset is exact and never asks about AM or PM")
    func relativeOffsetIsExact() throws {
        var spec = TimeSpec()
        spec.relative = RelativeOffset(unit: .minute, value: 5)
        let resolved = try #require(Fixture.resolver().resolve(spec, now: Fixture.now))
        #expect(resolved.date.timeIntervalSince(Fixture.now) == 300)
        #expect(!resolved.meridiemWasGuessed)
        #expect(!resolved.timeWasDefaulted)
    }

    @Test("An empty spec resolves to nothing rather than to a guess")
    func emptySpecIsNil() {
        #expect(Fixture.resolver().resolve(TimeSpec(), now: Fixture.now) == nil)
    }

    // MARK: - Daylight saving

    @Test("A daily alarm keeps its wall-clock hour across a daylight-saving change")
    func dailyAlarmSurvivesDST() {
        // Stepped one day at a time through Lebanon's spring-forward weekend. Adding 86,400 seconds
        // instead of one calendar day is what silently turns a 07:00 alarm into a 06:00 one.
        let engine = RecurrenceEngine(calendar: Fixture.calendar)
        var cursor = Fixture.at(2026, 3, 26, 7, 0)
        for step in 1...6 {
            guard let next = engine.advance(cursor, by: .everyNDays(1)) else {
                Issue.record("recurrence stopped at step \(step)")
                return
            }
            cursor = next
            #expect(Fixture.calendar.component(.hour, from: cursor) == 7,
                    "step \(step) drifted off 07:00")
            #expect(Fixture.calendar.component(.minute, from: cursor) == 0)
        }
    }

    @Test("A weekly alarm keeps its wall-clock hour across a daylight-saving change")
    func weeklyAlarmSurvivesDST() {
        let engine = RecurrenceEngine(calendar: Fixture.calendar)
        var cursor = Fixture.at(2026, 3, 23, 7, 0)          // a Monday before the change
        for _ in 1...4 {
            guard let next = engine.advance(cursor, by: .weekly(days: [2])) else { return }
            cursor = next
            #expect(Fixture.calendar.component(.hour, from: cursor) == 7)
            #expect(Fixture.calendar.component(.weekday, from: cursor) == 2)
        }
    }
}
