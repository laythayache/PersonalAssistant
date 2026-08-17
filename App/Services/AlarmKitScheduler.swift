import Foundation
import SwiftUI
// `LiveActivityIntent` is an AppIntents type, not an AlarmKit one — AlarmKit only takes it as a
// parameter. Without this import the intent arguments fail to type-check, which in turn makes
// AlarmConfiguration's Metadata generic un-inferrable.
import AppIntents

#if canImport(AlarmKit)
import AlarmKit
#endif

/// Everything the app says to the system alarm clock.
///
/// Main-actor isolated to match `AlarmScheduling`. It is called only from the executor, the
/// reconciler and the review service — all of which are already on the main actor — and it logs
/// through `DebugLog`, which is main-actor too. Leaving it nonisolated bought nothing and made
/// every log line a cross-actor hop.
@MainActor
final class AlarmKitScheduler: AlarmScheduling {

    /// Alarms scheduled as a rolling window can pile up; the system enforces its own ceiling and
    /// throws `maximumLimitReached`. That error is surfaced, never swallowed.
    static let snoozeIsEnabled = true

    func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            switch manager.authorizationState {
            case .authorized:
                return true
            case .denied:
                DebugLog.shared.log("alarmkit", "authorization previously denied")
                return false
            default:
                do {
                    let state = try await manager.requestAuthorization()
                    let granted = (state == .authorized)
                    DebugLog.shared.log("alarmkit", "authorization request returned granted=\(granted)")
                    return granted
                } catch {
                    DebugLog.shared.error("alarmkit", "authorization request failed: \(error.localizedDescription)")
                    return false
                }
            }
        }
        #endif
        return false
    }

    func isAuthorized() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return AlarmManager.shared.authorizationState == .authorized
        }
        #endif
        return false
    }

    func scheduledAlarmIDs() async -> Set<UUID> {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                return Set(try AlarmManager.shared.alarms.map(\.id))
            } catch {
                DebugLog.shared.error("alarmkit", "could not read system alarms: \(error.localizedDescription)")
                return []
            }
        }
        #endif
        return []
    }

    func schedule(_ request: AlarmScheduleRequest) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let metadata = AssistantAlarmMetadata(occurrenceID: request.id,
                                                  itemID: request.itemID,
                                                  title: request.title,
                                                  projectName: request.projectName,
                                                  kind: request.kind.rawValue)

            let allowSnooze = Self.snoozeIsEnabled && request.allowSnooze
            let isReview = request.kind == .dailyReview

            let stopButton = AlarmButton(text: isReview ? "Later" : "Stop",
                                         textColor: .white,
                                         systemImageName: "stop.fill")

            // The Daily Review alarm's second button opens the app straight into the review.
            // LiveActivityIntent runs in the app's process, so this needs no App Group.
            let secondaryButton: AlarmButton?
            let secondaryBehavior: AlarmPresentation.Alert.SecondaryButtonBehavior?
            let secondaryIntent: (any LiveActivityIntent)?

            if isReview {
                secondaryButton = AlarmButton(text: "Review",
                                              textColor: .white,
                                              systemImageName: "checklist")
                secondaryBehavior = .custom
                secondaryIntent = OpenDailyReviewIntent(occurrenceID: request.id)
            } else if allowSnooze {
                secondaryButton = AlarmButton(text: "Snooze",
                                              textColor: .white,
                                              systemImageName: "zzz")
                secondaryBehavior = .countdown
                secondaryIntent = nil
            } else {
                secondaryButton = nil
                secondaryBehavior = nil
                secondaryIntent = nil
            }

            let alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: request.title),
                stopButton: stopButton,
                secondaryButton: secondaryButton,
                secondaryButtonBehavior: secondaryBehavior)

            let presentation: AlarmPresentation
            if allowSnooze && !isReview {
                let countdown = AlarmPresentation.Countdown(
                    title: LocalizedStringResource(stringLiteral: request.title),
                    pauseButton: AlarmButton(text: "Pause",
                                             textColor: .white,
                                             systemImageName: "pause.fill"))
                presentation = AlarmPresentation(alert: alert, countdown: countdown)
            } else {
                presentation = AlarmPresentation(alert: alert)
            }

            let attributes = AlarmAttributes(presentation: presentation,
                                             metadata: metadata,
                                             tintColor: Color.accentColor)

            let schedule: Alarm.Schedule
            switch request.mode {
            case .fixed(let date):
                schedule = .fixed(date)
            case .weekly(let hour, let minute, let days):
                let weekdays = days.sorted().compactMap(Self.systemWeekday)
                guard !weekdays.isEmpty else {
                    throw AlarmSchedulingError.invalidRequest("weekly rule had no valid weekdays")
                }
                schedule = .relative(Alarm.Schedule.Relative(
                    time: Alarm.Schedule.Relative.Time(hour: hour, minute: minute),
                    repeats: .weekly(weekdays)))
            }

            let countdownDuration: Alarm.CountdownDuration? = (allowSnooze && !isReview)
                ? Alarm.CountdownDuration(preAlert: nil,
                                          postAlert: TimeInterval(request.snoozeMinutes * 60))
                : nil

            let configuration = AlarmManager.AlarmConfiguration(
                countdownDuration: countdownDuration,
                schedule: schedule,
                attributes: attributes,
                stopIntent: StopAssistantAlarmIntent(occurrenceID: request.id),
                secondaryIntent: secondaryIntent,
                sound: .default)

            do {
                _ = try await AlarmManager.shared.schedule(id: request.id, configuration: configuration)
                DebugLog.shared.log("alarmkit", "scheduled \(request.id) — \(request.title)")
            } catch {
                throw Self.translate(error)
            }
            return
        }
        #endif
        throw AlarmSchedulingError.underlying("AlarmKit is unavailable on this OS version.")
    }

    func cancel(id: UUID) async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                try AlarmManager.shared.cancel(id: id)
                DebugLog.shared.log("alarmkit", "cancelled \(id)")
            } catch {
                // A cancel for an alarm the system already dropped is a success, not a failure —
                // the desired end state (no such alarm) is what we have.
                DebugLog.shared.log("alarmkit", "cancel \(id) reported: \(error.localizedDescription)")
            }
        }
        #endif
    }

    // MARK: - Helpers

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func systemWeekday(_ calendarWeekday: Int) -> Locale.Weekday? {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    @available(iOS 26.0, *)
    private static func translate(_ error: Error) -> AlarmSchedulingError {
        let text = String(describing: error).lowercased()
        if text.contains("maximumlimitreached") || text.contains("limit") {
            DebugLog.shared.error("alarmkit", "system alarm limit reached")
            return .systemLimitReached
        }
        if text.contains("authoriz") || text.contains("denied") {
            return .notAuthorized
        }
        DebugLog.shared.error("alarmkit", "schedule failed: \(error.localizedDescription)")
        return .underlying(error.localizedDescription)
    }
    #endif
}
