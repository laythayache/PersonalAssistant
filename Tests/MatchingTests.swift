import Testing
import Foundation
@testable import PersonalAssistant

/// Requirement 12's hard rule: never cancel or modify the wrong alarm on a weak guess.
@Suite("Picking which alarm you meant")
struct MatchingTests {

    private func candidate(_ title: String, _ date: Date, original: String? = nil, project: String = "Life") -> MatchCandidate {
        MatchCandidate(id: UUID(),
                       itemID: UUID(),
                       title: title,
                       originalText: original ?? title,
                       projectName: project,
                       scheduledAt: date,
                       status: .scheduled)
    }

    private func decide(_ candidates: [MatchCandidate],
                        query: String?,
                        targetAt: Date? = nil,
                        hasClock: Bool = false) -> OccurrenceMatcher.Decision {
        let ranked = OccurrenceMatcher.rank(candidates: candidates,
                                            query: query,
                                            targetAt: targetAt,
                                            targetHasClock: hasClock,
                                            now: Fixture.now,
                                            calendar: Fixture.calendar)
        return OccurrenceMatcher.decide(ranked)
    }

    @Test("One clear match is acted on")
    func singleMatchIsUnique() {
        let riad = candidate("call Riad", Fixture.at(2026, 8, 20, 16, 0))
        let gym = candidate("gym", Fixture.at(2026, 8, 20, 7, 0))

        guard case .unique(let chosen) = decide([riad, gym], query: "Riad") else {
            Issue.record("expected a unique match")
            return
        }
        #expect(chosen.id == riad.id)
    }

    @Test("Two equally good matches produce a question, not a coin toss")
    func tiedMatchesAsk() {
        let first = candidate("call Riad", Fixture.at(2026, 8, 20, 16, 0))
        let second = candidate("call Riad again", Fixture.at(2026, 8, 20, 18, 0))

        guard case .ambiguous(let choices) = decide([first, second], query: "Riad") else {
            Issue.record("expected ambiguity")
            return
        }
        #expect(choices.count == 2)
    }

    @Test("A word that identifies nothing matches nothing")
    func noiseWordsMatchNothing() {
        let gym = candidate("gym", Fixture.at(2026, 8, 20, 7, 0))
        #expect(decide([gym], query: "the alarm") == .none,
                "'the alarm' is not a description of which alarm")
    }

    @Test("An Arabic title is findable by an English description of it")
    func crossScriptMatch() {
        // The alarm was created in Arabizi; the user later refers to it in English.
        let riad = candidate("etsel b Riad",
                             Fixture.at(2026, 8, 20, 16, 0),
                             original: "zakkerne bokra 4 etsel b Riad")
        let gym = candidate("gym", Fixture.at(2026, 8, 20, 7, 0))

        guard case .unique(let chosen) = decide([riad, gym], query: "Riad") else {
            Issue.record("expected a unique match against the stored original text")
            return
        }
        #expect(chosen.id == riad.id)
    }

    @Test("A clock time alone is enough to identify an alarm")
    func clockOnlyMatch() {
        let four = candidate("dentist", Fixture.at(2026, 8, 19, 16, 0))
        let seven = candidate("gym", Fixture.at(2026, 8, 20, 7, 0))

        guard case .unique(let chosen) = decide([four, seven],
                                                query: nil,
                                                targetAt: Fixture.at(2026, 8, 19, 16, 0),
                                                hasClock: true) else {
            Issue.record("expected the 4 PM alarm")
            return
        }
        #expect(chosen.id == four.id)
    }

    @Test("A day with two alarms and no other clue asks which one")
    func dayOnlyWithTwoAlarmsAsks() {
        let a = candidate("dentist", Fixture.at(2026, 8, 20, 16, 0))
        let b = candidate("gym", Fixture.at(2026, 8, 20, 7, 0))

        let decision = decide([a, b], query: nil, targetAt: Fixture.at(2026, 8, 20, 9, 0), hasClock: false)
        guard case .ambiguous = decision else {
            Issue.record("naming only a day must not pick one of two alarms, got \(decision)")
            return
        }
    }

    @Test("Collisions are detected on the minute and ignore the same item")
    func collisionWindow() {
        let at1600 = Fixture.at(2026, 8, 20, 16, 0)
        let itemID = UUID()
        let slots = [
            AlarmSlot(id: UUID(), itemID: itemID, title: "dentist", projectName: "Life", scheduledAt: at1600),
            AlarmSlot(id: UUID(), itemID: UUID(), title: "gym", projectName: "Life",
                      scheduledAt: Fixture.at(2026, 8, 20, 16, 5))
        ]

        #expect(CollisionDetector.conflicts(at: at1600, among: slots).count == 1)
        #expect(CollisionDetector.conflicts(at: at1600, among: slots, excludingItem: itemID).isEmpty,
                "moving an alarm must not collide with itself")
        #expect(CollisionDetector.conflicts(at: Fixture.at(2026, 8, 20, 16, 2), among: slots).isEmpty,
                "two minutes apart is not a collision")
    }
}
