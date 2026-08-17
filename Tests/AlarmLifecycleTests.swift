import Testing
import Foundation
@testable import PersonalAssistant

/// The end-to-end cases from requirement 19, run against a real SwiftData store and a fake system
/// alarm clock. These are the ones that prove the app does its job rather than merely not crashing.
@Suite("Alarm lifecycle")
@MainActor
struct AlarmLifecycleTests {

    // MARK: - Creation

    @Test("Creating an alarm persists it and registers it with the system")
    func createRegisters() async throws {
        let env = try Fixture.makeEnvironment()
        let command = Fixture.parse("Remind me in 5 minutes to test this.")

        let outcome = await env.executor.execute(command, now: Fixture.now)
        guard case .created(let result) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(result.schedulingProblem == nil)

        let occurrence = try #require(env.store.occurrence(id: result.occurrenceID))
        #expect(occurrence.status == .scheduled)
        #expect(occurrence.isRegisteredWithAlarmKit)
        #expect(occurrence.scheduledAt == Fixture.now.addingTimeInterval(300))
        #expect(occurrence.item?.title == "test this")
        #expect(occurrence.item?.originalText == "Remind me in 5 minutes to test this.",
                "the words typed are kept verbatim")
        #expect(occurrence.item?.project?.name == Constants.defaultProjectName,
                "an unassigned item belongs to Life, never to nothing")

        #expect(env.scheduler.ids == [occurrence.id],
                "exactly one system alarm, under the occurrence's own UUID")
    }

    @Test("A failed system registration still keeps the request")
    func schedulingFailureIsNotSilent() async throws {
        let env = try Fixture.makeEnvironment()
        env.scheduler.failNextSchedule = .systemLimitReached

        let outcome = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."),
                                                 now: Fixture.now)
        guard case .created(let result) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(result.schedulingProblem != nil, "the user is told, not left assuming it worked")

        let occurrence = try #require(env.store.occurrence(id: result.occurrenceID))
        #expect(!occurrence.isRegisteredWithAlarmKit)
        #expect(occurrence.status == .scheduled, "so the reconciler will retry it")
        #expect(env.store.events().contains { $0.kind == .schedulingFailed })
    }

    // MARK: - Collision

    @Test("A second alarm on the same minute asks instead of stacking")
    func collisionAsks() async throws {
        let env = try Fixture.makeEnvironment()
        let first = Fixture.parse("Remind me in 5 minutes to test this.")
        _ = await env.executor.execute(first, now: Fixture.now)

        let second = Fixture.parse("Remind me in 5 minutes to call the bank.")
        let outcome = await env.executor.execute(second, now: Fixture.now)

        guard case .collision(let prompt) = outcome else {
            Issue.record("expected .collision, got \(outcome)")
            return
        }
        #expect(prompt.existing.count == 1)
        #expect(prompt.existing.first?.title == "test this")
        #expect(env.scheduler.ids.count == 1, "nothing was created behind the question")
    }

    @Test("Keep both creates the second alarm as well")
    func collisionKeepBoth() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."), now: Fixture.now)
        let outcome = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to call the bank."),
                                                 now: Fixture.now)
        guard case .collision(let prompt) = outcome else {
            Issue.record("expected .collision")
            return
        }

        _ = await env.executor.resolveCollision(prompt, with: .keepBoth, newTime: nil, now: Fixture.now)
        #expect(env.scheduler.ids.count == 2)
        #expect(env.store.upcoming(from: Fixture.now).count == 2)
    }

    @Test("Replace existing cancels the old one and keeps its history")
    func collisionReplace() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."), now: Fixture.now)
        let outcome = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to call the bank."),
                                                 now: Fixture.now)
        guard case .collision(let prompt) = outcome else {
            Issue.record("expected .collision")
            return
        }

        _ = await env.executor.resolveCollision(prompt, with: .replaceExisting, newTime: nil, now: Fixture.now)
        #expect(env.scheduler.ids.count == 1, "only the replacement is live")

        let all = env.store.allOccurrences()
        #expect(all.count == 2, "the replaced one is kept as history, not deleted")
        #expect(all.contains { $0.status == .cancelled })
        #expect(all.contains { $0.status == .scheduled })
    }

    @Test("Postpone existing moves the old alarm and creates the new one")
    func collisionPostponeExisting() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."), now: Fixture.now)
        let outcome = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to call the bank."),
                                                 now: Fixture.now)
        guard case .collision(let prompt) = outcome else {
            Issue.record("expected .collision")
            return
        }

        let movedTo = Fixture.now.addingTimeInterval(3600)
        _ = await env.executor.resolveCollision(prompt, with: .postponeExisting, newTime: movedTo, now: Fixture.now)

        #expect(env.scheduler.ids.count == 2)
        let postponed = env.store.allOccurrences().first { $0.status == .postponed }
        #expect(postponed != nil, "the original is preserved as postponed")
        #expect(postponed?.postponedToID != nil)
    }

    // MARK: - Postpone

    @Test("Postponing preserves the old occurrence and links both directions")
    func postponeKeepsHistory() async throws {
        let env = try Fixture.makeEnvironment()
        let created = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else {
            Issue.record("expected .created")
            return
        }
        let originalID = result.occurrenceID
        let originalDate = try #require(env.store.occurrence(id: originalID)).scheduledAt

        let outcome = await env.executor.execute(Fixture.parse("Postpone the Riad alarm until Friday at 11."),
                                                 now: Fixture.now)
        guard case .reply = outcome else {
            Issue.record("expected a plain confirmation, got \(outcome)")
            return
        }

        let old = try #require(env.store.occurrence(id: originalID))
        #expect(old.status == .postponed)
        #expect(old.originalScheduledAt == originalDate, "the original time is still readable")
        let newID = try #require(old.postponedToID)

        let new = try #require(env.store.occurrence(id: newID))
        #expect(new.postponedFromID == originalID)
        #expect(new.status == .scheduled)
        #expect(Fixture.parts(new.scheduledAt).day == 21)
        #expect(Fixture.parts(new.scheduledAt).hour == 11)

        #expect(!env.scheduler.ids.contains(originalID), "the old system alarm is gone")
        #expect(env.scheduler.ids.contains(newID))
    }

    @Test("Postponing to a day with no time keeps the original time of day")
    func postponeCarriesTimeOfDay() async throws {
        let env = try Fixture.makeEnvironment()
        let created = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else { return }

        _ = await env.executor.execute(Fixture.parse("Move the Riad thing to Friday."), now: Fixture.now)

        let old = try #require(env.store.occurrence(id: result.occurrenceID))
        let new = try #require(env.store.occurrence(id: try #require(old.postponedToID)))
        #expect(Fixture.parts(new.scheduledAt).day == 21)
        #expect(Fixture.parts(new.scheduledAt).hour == 16,
                "16:00 was carried over rather than replaced by the default hour")
    }

    // MARK: - Cancel

    @Test("Cancelling updates the store and the system together")
    func cancelUpdatesBoth() async throws {
        let env = try Fixture.makeEnvironment()
        let created = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else { return }
        #expect(env.scheduler.ids.contains(result.occurrenceID))

        _ = await env.executor.execute(Fixture.parse("Cancel the Riad alarm."), now: Fixture.now)

        let occurrence = try #require(env.store.occurrence(id: result.occurrenceID))
        #expect(occurrence.status == .cancelled)
        #expect(!occurrence.isRegisteredWithAlarmKit)
        #expect(!env.scheduler.ids.contains(result.occurrenceID))
        #expect(env.store.allOccurrences().count == 1, "cancelled means marked, not deleted")
    }

    @Test("An ambiguous cancel asks rather than guessing")
    func ambiguousCancelAsks() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."), now: Fixture.now)
        _ = await env.executor.execute(Fixture.parse("Remind me tomorrow at 6 to call Riad again."), now: Fixture.now)

        let outcome = await env.executor.execute(Fixture.parse("Cancel the Riad alarm."), now: Fixture.now)
        guard case .disambiguation(let prompt) = outcome else {
            Issue.record("expected .disambiguation, got \(outcome)")
            return
        }
        #expect(prompt.choices.count == 2)
        #expect(env.store.allOccurrences().allSatisfy { $0.status == .scheduled },
                "nothing was cancelled while the question was open")
    }

    // MARK: - Recurrence

    @Test("A weekly alarm takes one system slot, not many")
    func weeklyUsesOneSystemAlarm() async throws {
        let env = try Fixture.makeEnvironment()
        let outcome = await env.executor.execute(
            Fixture.parse("Every Monday at 9 remind me to send the report."), now: Fixture.now)
        guard case .created(let result) = outcome else {
            Issue.record("expected .created")
            return
        }
        #expect(env.scheduler.ids.count == 1)

        let request = try #require(env.scheduler.requests[result.occurrenceID])
        guard case .weekly(let hour, let minute, let days) = request.mode else {
            Issue.record("expected a native weekly schedule, got \(request.mode)")
            return
        }
        #expect(hour == 9)
        #expect(minute == 0)
        #expect(days == [2])
    }

    @Test("Every 3 days books a rolling window of separate system alarms")
    func rollingRecurrenceBooksAhead() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Remind me every 3 days to check this."), now: Fixture.now)

        #expect(env.scheduler.ids.count == Constants.rollingHorizonCount,
                "AlarmKit cannot repeat every 3 days, so the app pre-books the window itself")
        #expect(env.store.upcoming(from: Fixture.now).count == Constants.rollingHorizonCount)
        #expect(env.scheduler.requests.values.allSatisfy { $0.fixedDate != nil })
    }

    // MARK: - Reconciliation

    @Test("An alarm the system lost is re-registered under the same UUID")
    func reconcileRepairsWithoutDuplicating() async throws {
        let env = try Fixture.makeEnvironment()
        let created = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else { return }

        // A reboot, a restore, or an OS hiccup: the alarm is simply gone from the system.
        env.scheduler.simulateSystemLoss(of: result.occurrenceID)
        #expect(env.scheduler.ids.isEmpty)

        let report = await env.reconciler.reconcile(now: Fixture.now)
        #expect(report.repaired == 1)
        #expect(env.scheduler.ids == [result.occurrenceID], "same UUID, so no duplicate is possible")

        // Running it again must be a no-op rather than a second registration.
        let second = await env.reconciler.reconcile(now: Fixture.now)
        #expect(second.repaired == 0)
        #expect(env.scheduler.ids.count == 1)
    }

    @Test("An alarm the app has no record of is removed")
    func reconcileRemovesOrphans() async throws {
        let env = try Fixture.makeEnvironment()
        let stray = UUID()
        env.scheduler.simulateOrphan(stray)

        let report = await env.reconciler.reconcile(now: Fixture.now)
        #expect(report.orphansRemoved == 1)
        #expect(!env.scheduler.ids.contains(stray))
    }

    @Test("An alarm whose time passed while the app was closed becomes reviewable")
    func reconcileMarksPassedAlarms() async throws {
        let env = try Fixture.makeEnvironment()
        let created = await env.executor.execute(Fixture.parse("Remind me tomorrow at 4 to call Riad."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else { return }

        // Come back two days later without ever having opened the app.
        let later = Fixture.at(2026, 8, 21, 10, 0)
        let report = await env.reconciler.reconcile(now: later)

        #expect(report.markedPending == 1)
        #expect(try #require(env.store.occurrence(id: result.occurrenceID)).status == .pendingReview)
        #expect(env.review.daysNeedingReview(now: later).contains("2026-08-20"),
                "so the chat shows a review badge for the day that was missed")
    }

    @Test("A weekly series rolls its next occurrence forward as each one fires")
    func weeklySeriesRollsForward() async throws {
        let env = try Fixture.makeEnvironment()
        _ = await env.executor.execute(Fixture.parse("Every Monday at 9 remind me to send the report."),
                                       now: Fixture.now)

        // The Monday passes.
        let afterMonday = Fixture.at(2026, 8, 24, 10, 0)
        let report = await env.reconciler.reconcile(now: afterMonday)
        #expect(report.seriesRolledForward == 1)

        let scheduled = env.store.upcoming(from: afterMonday)
        #expect(scheduled.count == 1)
        #expect(Fixture.parts(try #require(scheduled.first).scheduledAt).day == 31,
                "the following Monday")
        #expect(env.scheduler.ids.count == 1, "still one system alarm for the whole series")
    }

    // MARK: - Daily review

    @Test("A day with alarms gets an evening review; a day without one does not")
    func dailyReviewIsConditional() async throws {
        let env = try Fixture.makeEnvironment()
        let settings = env.store.settings()
        settings.endOfDayHour = 21
        settings.endOfDayMinute = 0
        env.store.save("test settings")

        // An empty day must not create any review work.
        await env.review.reconcileReview(forDayKey: "2026-08-19", now: Fixture.now)
        #expect(env.store.occurrences(onDayKey: "2026-08-19").isEmpty,
                "no alarms that day, so no review is required")

        // One real alarm is enough to earn one.
        _ = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."), now: Fixture.now)

        let today = env.store.occurrences(onDayKey: "2026-08-19")
        let reviews = today.filter { $0.kind == .dailyReview }
        #expect(reviews.count == 1)
        #expect(Fixture.parts(try #require(reviews.first).scheduledAt).hour == 21)
        #expect(env.scheduler.ids.count == 2, "the alarm and its review")
    }

    @Test("No review time was configured means no review alarm is ever invented")
    func reviewNeedsAnExplicitTime() async throws {
        let env = try Fixture.makeEnvironment()
        // Settings left untouched: endOfDayHour is nil.
        _ = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."), now: Fixture.now)

        let reviews = env.store.occurrences(onDayKey: "2026-08-19").filter { $0.kind == .dailyReview }
        #expect(reviews.isEmpty, "requirement 11: the review time is asked for, never guessed")
    }

    @Test("Cancelling the last alarm of a day withdraws that day's review")
    func reviewWithdrawnWhenDayEmpties() async throws {
        let env = try Fixture.makeEnvironment()
        let settings = env.store.settings()
        settings.endOfDayHour = 21
        settings.endOfDayMinute = 0
        env.store.save("test settings")

        let created = await env.executor.execute(Fixture.parse("Remind me in 5 minutes to test this."),
                                                 now: Fixture.now)
        guard case .created(let result) = created else { return }
        #expect(env.store.occurrences(onDayKey: "2026-08-19").contains { $0.kind == .dailyReview })

        await env.executor.setStatus(occurrenceID: result.occurrenceID, to: .cancelled, now: Fixture.now)
        await env.review.reconcileReview(forDayKey: "2026-08-19", now: Fixture.now)

        let liveReviews = env.store.occurrences(onDayKey: "2026-08-19")
            .filter { $0.kind == .dailyReview && $0.status != .cancelled }
        #expect(liveReviews.isEmpty)
    }

    @Test("Review notes are kept permanently")
    func reviewNotesPersist() async throws {
        let env = try Fixture.makeEnvironment()
        env.review.completeReview(dayKey: "2026-08-19",
                                  notes: "Unplanned: power cut for two hours.",
                                  now: Fixture.now)

        let log = env.store.dailyLog(for: "2026-08-19", calendar: Fixture.calendar)
        #expect(log.notes == "Unplanned: power cut for two hours.")
        #expect(log.reviewCompletedAt != nil)
    }
}
