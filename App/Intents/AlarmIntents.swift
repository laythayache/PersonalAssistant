import AppIntents
import Foundation
import SwiftData

#if canImport(AlarmKit)
import AlarmKit
#endif

/// Buttons on a ringing alarm.
///
/// `LiveActivityIntent` runs `perform()` in the app's own process, waking it if necessary. That is
/// what lets these write to the store and route the UI without an App Group — and no App Group is
/// what keeps this project signable under a free Apple ID.

struct StopAssistantAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"
    static var description = IntentDescription("Stops a ringing assistant alarm.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Occurrence")
    var occurrenceID: String

    init() {}

    init(occurrenceID: UUID) {
        self.occurrenceID = occurrenceID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: occurrenceID) else { return .result() }

        // Supplying a custom stopIntent means AlarmKit hands us the Stop press instead of handling
        // it. If this call is missed the alarm keeps ringing, so it comes first.
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                try AlarmManager.shared.stop(id: id)
            } catch {
                DebugLog.shared.error("alarmkit", "stop(\(id)) failed: \(error.localizedDescription)")
            }
        }
        #endif

        AlarmSideEffects.markFired(occurrenceID: id)
        return .result()
    }
}

struct OpenDailyReviewIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open Daily Review"
    static var description = IntentDescription("Opens today's end-of-day review.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    @Parameter(title: "Occurrence")
    var occurrenceID: String

    init() {}

    init(occurrenceID: UUID) {
        self.occurrenceID = occurrenceID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: occurrenceID) else { return .result() }

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            try? AlarmManager.shared.stop(id: id)
        }
        #endif

        let dayKey = AlarmSideEffects.markFired(occurrenceID: id) ?? DayKey.today()
        AppRouter.shared.request(.dailyReview(dayKey: dayKey))
        return .result()
    }
}

/// Store writes that happen from an intent rather than from the UI.
@MainActor
enum AlarmSideEffects {

    /// Moves a fired occurrence out of `.scheduled` so the reconciler does not later mistake it for
    /// an alarm the system lost. Returns the day it belonged to.
    @discardableResult
    static func markFired(occurrenceID: UUID) -> String? {
        let context = PersistenceController.makeContext()
        let descriptor = FetchDescriptor<AlarmOccurrence>(
            predicate: #Predicate { $0.id == occurrenceID })

        guard let occurrence = try? context.fetch(descriptor).first else {
            DebugLog.shared.log("intent", "fired alarm \(occurrenceID) has no stored occurrence")
            return nil
        }

        if occurrence.status == .scheduled {
            occurrence.status = .pendingReview
            occurrence.isRegisteredWithAlarmKit = false
            context.insert(Event(kind: .occurrenceMissed,
                                 detail: "Alarm rang and was stopped; awaiting review.",
                                 itemID: occurrence.item?.id,
                                 occurrenceID: occurrence.id))
            try? context.save()
            DebugLog.shared.log("intent", "occurrence \(occurrenceID) moved to pendingReview")
        }
        return occurrence.dayKey
    }
}
