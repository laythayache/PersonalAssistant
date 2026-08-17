import Foundation

/// Requirement 20: the store and AlarmKit must never silently drift apart.
///
/// Runs on launch and on every foreground. The system's alarm list is treated as the truth about
/// what will actually ring; the store is the truth about what the user asked for. Where they
/// disagree, the store is re-imposed on the system, because a missing alarm is the failure that
/// matters and a duplicate is prevented by reusing the same UUID.
@MainActor
final class Reconciler {

    struct Report: Equatable {
        var repaired = 0
        var orphansRemoved = 0
        var markedPending = 0
        var seriesRolledForward = 0
        var toppedUp = 0
        var failures: [String] = []
        var authorized = true

        var didAnything: Bool {
            repaired + orphansRemoved + markedPending + seriesRolledForward + toppedUp > 0
                || !failures.isEmpty
        }

        var summary: String {
            var parts: [String] = []
            if repaired > 0 { parts.append("re-registered \(repaired)") }
            if orphansRemoved > 0 { parts.append("removed \(orphansRemoved) orphaned") }
            if markedPending > 0 { parts.append("\(markedPending) awaiting review") }
            if seriesRolledForward > 0 { parts.append("rolled \(seriesRolledForward) repeat(s) forward") }
            if toppedUp > 0 { parts.append("topped up \(toppedUp)") }
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        }
    }

    private let store: Store
    private let scheduler: AlarmScheduling
    private let review: DailyReviewService
    private let calendar: Calendar
    private let engine: RecurrenceEngine

    init(store: Store, scheduler: AlarmScheduling, review: DailyReviewService, calendar: Calendar = .current) {
        self.store = store
        self.scheduler = scheduler
        self.review = review
        self.calendar = calendar
        self.engine = RecurrenceEngine(calendar: calendar)
    }

    @discardableResult
    func reconcile(now: Date = .now) async -> Report {
        var report = Report()

        guard await scheduler.isAuthorized() else {
            report.authorized = false
            DebugLog.shared.log("reconcile", "skipped — alarm permission not granted")
            return report
        }

        let systemIDs = await scheduler.scheduledAlarmIDs()
        let occurrences = store.allOccurrences()

        // 1. Occurrences whose time has passed while the app was not running.
        for occurrence in occurrences where occurrence.status == .scheduled && occurrence.scheduledAt <= now {
            occurrence.status = .pendingReview
            occurrence.isRegisteredWithAlarmKit = false
            store.logEvent(.reconcileMarkedPending,
                           "Fire time passed while the app was closed.",
                           itemID: occurrence.item?.id, occurrenceID: occurrence.id)
            report.markedPending += 1

            // A natively repeating series keeps one system alarm alive forever, so the store needs
            // the next step written as this one retires.
            if occurrence.belongsToNativeSeries,
               let item = occurrence.item, !item.isCancelled,
               let next = nextFireDate(after: occurrence.scheduledAt, rule: item.recurrence, now: now) {
                let follow = AlarmOccurrence(id: UUID(),
                                             alarmKitID: occurrence.alarmKitID,
                                             scheduledAt: next,
                                             dayKey: DayKey.make(for: next, calendar: calendar),
                                             item: item)
                follow.isRegisteredWithAlarmKit = true
                store.context.insert(follow)
                report.seriesRolledForward += 1
            }
        }
        store.save("reconcile pending")

        // 2. Future alarms the system no longer holds. Re-register under the same UUID.
        var knownAlarmKitIDs: Set<UUID> = []
        for occurrence in store.allOccurrences() {
            if let id = occurrence.alarmKitID { knownAlarmKitIDs.insert(id) }
        }

        var alreadyRepairedSeries: Set<UUID> = []
        for occurrence in store.allOccurrences()
        where occurrence.status == .scheduled && occurrence.scheduledAt > now {
            guard let item = occurrence.item, !item.isCancelled else { continue }
            guard let alarmKitID = occurrence.alarmKitID else { continue }

            if systemIDs.contains(alarmKitID) {
                occurrence.isRegisteredWithAlarmKit = true
                continue
            }
            // One repair per weekly series, not one per occurrence.
            if occurrence.belongsToNativeSeries {
                if alreadyRepairedSeries.contains(alarmKitID) { continue }
                alreadyRepairedSeries.insert(alarmKitID)
            }

            let mode: AlarmScheduleRequest.Mode
            if occurrence.belongsToNativeSeries, case .weekly(let days) = item.recurrence {
                let time = engine.timeComponents(of: occurrence.scheduledAt)
                mode = .weekly(hour: time.hour, minute: time.minute, days: days)
            } else {
                mode = .fixed(occurrence.scheduledAt)
            }

            let request = AlarmScheduleRequest(id: alarmKitID,
                                               itemID: item.id,
                                               title: item.title,
                                               projectName: item.project?.name ?? Constants.defaultProjectName,
                                               kind: item.kind,
                                               mode: mode,
                                               allowSnooze: item.kind != .dailyReview,
                                               snoozeMinutes: store.settings().snoozeMinutes)
            do {
                try await scheduler.schedule(request)
                occurrence.isRegisteredWithAlarmKit = true
                store.logEvent(.reconcileRepaired,
                               "Re-registered a missing system alarm.",
                               itemID: item.id, occurrenceID: occurrence.id)
                report.repaired += 1
            } catch {
                let message = (error as? AlarmSchedulingError)?.errorDescription ?? error.localizedDescription
                occurrence.isRegisteredWithAlarmKit = false
                store.logEvent(.schedulingFailed, "Repair failed: \(message)",
                               itemID: item.id, occurrenceID: occurrence.id)
                report.failures.append("\(item.title): \(message)")
            }
        }
        store.save("reconcile repair")

        // 3. Alarms the system holds that this app has no record of at all.
        // Deliberately conservative: an ID attached to *any* stored occurrence, in any state, is
        // left alone. Only a completely unknown ID is removed.
        for orphan in systemIDs.subtracting(knownAlarmKitIDs) {
            await scheduler.cancel(id: orphan)
            store.logEvent(.reconcileOrphanRemoved, "Removed unknown system alarm \(orphan).")
            report.orphansRemoved += 1
        }

        // 4. Extend rolling recurrences that are running low.
        // Two statements, not one: assigning into `report` while also passing it inout would be
        // overlapping access to the same variable.
        let added = await topUpRollingSeries(now: now, report: &report)
        report.toppedUp = added
        store.save("reconcile top-up")

        // 5. Daily reviews for today and for anything still awaiting triage.
        var days = Set([DayKey.make(for: now, calendar: calendar)])
        days.formUnion(review.daysNeedingReview(now: now))
        for dayKey in days {
            await review.reconcileReview(forDayKey: dayKey, now: now)
        }

        DebugLog.shared.log("reconcile", report.summary)
        return report
    }

    // MARK: - Rolling series

    /// "Every 3 days" is not something AlarmKit can repeat, so the app keeps a window of individual
    /// alarms in front of the user and refills it on every launch. See ARCHITECTURE.md §2.
    private func topUpRollingSeries(now: Date, report: inout Report) async -> Int {
        var added = 0

        // Deduplicated by UUID rather than by putting model objects in a Set — identity on a
        // SwiftData object is not something to lean on for this.
        var seen: Set<UUID> = []
        var items: [AlarmItem] = []
        for occurrence in store.allOccurrences() {
            guard let item = occurrence.item, seen.insert(item.id).inserted else { continue }
            items.append(item)
        }

        for item in items {
            let rule = item.recurrence
            guard rule.isRepeating, !rule.isNativelySupportedByAlarmKit, !item.isCancelled else { continue }

            let future = item.occurrences
                .filter { $0.status == .scheduled && $0.scheduledAt > now }
                .sorted { $0.scheduledAt < $1.scheduledAt }
            let missing = Constants.rollingHorizonCount - future.count
            guard missing > 0 else { continue }

            // Continue from the furthest one already booked, or from the last known fire time.
            let anchor = future.last?.scheduledAt
                ?? item.occurrences.map(\.scheduledAt).max()
                ?? now
            let dates = engine.rollingDates(rule: rule, anchor: anchor, now: now, count: missing + 1)
                .filter { candidate in
                    !item.occurrences.contains { abs($0.scheduledAt.timeIntervalSince(candidate)) < 1 }
                }
                .prefix(missing)

            for date in dates {
                let occurrence = AlarmOccurrence(scheduledAt: date,
                                                 dayKey: DayKey.make(for: date, calendar: calendar),
                                                 item: item)
                store.context.insert(occurrence)

                let request = AlarmScheduleRequest(id: occurrence.id,
                                                   itemID: item.id,
                                                   title: item.title,
                                                   projectName: item.project?.name ?? Constants.defaultProjectName,
                                                   kind: item.kind,
                                                   mode: .fixed(date),
                                                   allowSnooze: item.kind != .dailyReview,
                                                   snoozeMinutes: store.settings().snoozeMinutes)
                do {
                    try await scheduler.schedule(request)
                    occurrence.isRegisteredWithAlarmKit = true
                    added += 1
                } catch {
                    let message = (error as? AlarmSchedulingError)?.errorDescription ?? error.localizedDescription
                    store.logEvent(.schedulingFailed, "Top-up failed: \(message)",
                                   itemID: item.id, occurrenceID: occurrence.id)
                    report.failures.append("\(item.title): \(message)")
                    // The ceiling applies to the whole app, so stop asking for more.
                    if case .systemLimitReached = (error as? AlarmSchedulingError) ?? .underlying("") {
                        return added
                    }
                }
            }
        }
        return added
    }

    private func nextFireDate(after date: Date, rule: RecurrenceRule, now: Date) -> Date? {
        var cursor = date
        for _ in 0..<400 {
            guard let next = engine.advance(cursor, by: rule) else { return nil }
            if next > now { return next }
            cursor = next
        }
        return nil
    }
}
