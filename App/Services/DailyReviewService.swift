import Foundation

/// Requirement 11.
///
/// The rule is conditional in both directions: a day with at least one real alarm gets a review
/// alarm that evening, and a day with none gets nothing at all. The evening time is asked for
/// during onboarding and is never invented — if it has not been set, no review is ever created.
@MainActor
final class DailyReviewService {
    private let store: Store
    private let scheduler: AlarmScheduling
    private let calendar: Calendar

    static let reviewTitle = "End of Day Review"

    init(store: Store, scheduler: AlarmScheduling, calendar: Calendar = .current) {
        self.store = store
        self.scheduler = scheduler
        self.calendar = calendar
    }

    /// Brings the review alarm for one day into line with what that day actually contains.
    /// Safe to call repeatedly — it is the reconciler's job as much as the executor's.
    func reconcileReview(forDayKey dayKey: String, now: Date = .now) async {
        let settings = store.settings()
        guard let hour = settings.endOfDayHour, let minute = settings.endOfDayMinute else {
            return   // Not configured. Requirement 11: never guess this time.
        }

        let all = store.occurrences(onDayKey: dayKey)
        let userAlarms = all.filter { $0.kind != .dailyReview && $0.status != .cancelled }
        let existingReview = all.first { $0.kind == .dailyReview && $0.status != .cancelled }

        guard !userAlarms.isEmpty else {
            // Every alarm for that day was cancelled. Do not make the user complete a review for
            // a day that ended up empty.
            if let existingReview, existingReview.status == .scheduled {
                await cancel(existingReview, reason: "No user alarms remain on \(dayKey).")
            }
            return
        }

        if existingReview != nil { return }

        guard let dayStart = DayKey.startOfDay(for: dayKey, calendar: calendar) else { return }
        let resolver = DateResolver(calendar: calendar)
        let reviewDate = resolver.compose(day: dayStart, hour: hour, minute: minute)

        guard reviewDate > now else {
            // The review time for this day has already gone by. Ringing now would be noise; the
            // review still appears in the app as outstanding.
            store.logEvent(.dailyReviewCreated,
                           "Review time for \(dayKey) had already passed; no alarm scheduled.")
            store.save("review time passed")
            return
        }

        let item = AlarmItem(title: Self.reviewTitle,
                             originalText: Self.reviewTitle,
                             kind: .dailyReview,
                             recurrence: .none,
                             project: store.defaultProject())
        store.context.insert(item)

        let occurrence = AlarmOccurrence(scheduledAt: reviewDate,
                                         dayKey: dayKey,
                                         item: item)
        store.context.insert(occurrence)

        let request = AlarmScheduleRequest(id: occurrence.id,
                                           itemID: item.id,
                                           title: Self.reviewTitle,
                                           projectName: item.project?.name ?? Constants.defaultProjectName,
                                           kind: .dailyReview,
                                           mode: .fixed(reviewDate),
                                           allowSnooze: false,
                                           snoozeMinutes: store.settings().snoozeMinutes)
        do {
            try await scheduler.schedule(request)
            occurrence.isRegisteredWithAlarmKit = true
            store.logEvent(.dailyReviewCreated,
                           "Review alarm for \(dayKey) at \(Phrasing.time(reviewDate)).",
                           itemID: item.id, occurrenceID: occurrence.id)
        } catch {
            occurrence.isRegisteredWithAlarmKit = false
            store.logEvent(.schedulingFailed,
                           "Review alarm for \(dayKey) could not be scheduled: \(error.localizedDescription)",
                           itemID: item.id, occurrenceID: occurrence.id)
            DebugLog.shared.error("review", "could not schedule review for \(dayKey): \(error.localizedDescription)")
        }

        let log = store.dailyLog(for: dayKey, calendar: calendar)
        log.reviewOccurrenceID = occurrence.id
        log.modifiedAt = .now
        store.save("ensure review")
    }

    private func cancel(_ occurrence: AlarmOccurrence, reason: String) async {
        if let alarmKitID = occurrence.alarmKitID {
            await scheduler.cancel(id: alarmKitID)
        }
        occurrence.status = .cancelled
        occurrence.isRegisteredWithAlarmKit = false
        store.logEvent(.occurrenceCancelled, reason, occurrenceID: occurrence.id)
        store.save("cancel review")
    }

    /// Days that still have something to triage. Drives the badge on the chat screen.
    func daysNeedingReview(now: Date = .now) -> [String] {
        let pending = store.allOccurrences()
            .filter { $0.status == .pendingReview && $0.kind != .dailyReview }
            .map(\.dayKey)
        return Array(Set(pending)).sorted()
    }

    /// Marks a review complete. The free-text notes are saved with it and kept permanently.
    func completeReview(dayKey: String, notes: String, now: Date = .now) {
        let log = store.dailyLog(for: dayKey, calendar: calendar)
        log.notes = notes
        log.reviewCompletedAt = now
        log.modifiedAt = now
        store.logEvent(.dailyReviewCompleted, "Review completed for \(dayKey).")
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.logEvent(.dailyNoteSaved, "Notes saved for \(dayKey).")
        }
        store.save("complete review")
    }
}
