import Foundation

/// Everything the app needs to say to the system alarm clock, and nothing about how it is said.
///
/// Only `AlarmKitScheduler` implements this against the real framework. The executor, the
/// reconciler and every test talk to this protocol, which is what makes the alarm behaviour
/// testable on a machine with no alarms at all.
///
/// Main-actor isolated because every caller already is, and because the store it is co-ordinated
/// with is a `ModelContext` that cannot leave the main actor anyway.
@MainActor
protocol AlarmScheduling: AnyObject {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    /// The IDs the *system* currently holds. The source of truth for reconciliation.
    func scheduledAlarmIDs() async -> Set<UUID>
    func schedule(_ request: AlarmScheduleRequest) async throws
    func cancel(id: UUID) async
}

struct AlarmScheduleRequest: Equatable {
    /// Also the `AlarmOccurrence.id`. Same UUID in the store and in AlarmKit, so re-scheduling a
    /// repair overwrites rather than duplicates.
    let id: UUID
    let itemID: UUID
    let title: String
    let projectName: String
    let kind: AlarmKind
    let mode: Mode
    let allowSnooze: Bool
    let snoozeMinutes: Int

    enum Mode: Equatable {
        /// A single instant. Used for one-shot alarms and for each step of a rolling recurrence.
        case fixed(Date)
        /// Handed straight to `Alarm.Schedule.Relative.Recurrence.weekly`, which the system then
        /// repeats forever without the app being involved again.
        case weekly(hour: Int, minute: Int, days: Set<Int>)
    }

    var fixedDate: Date? {
        if case .fixed(let date) = mode { return date }
        return nil
    }
}

enum AlarmSchedulingError: LocalizedError, Equatable {
    case notAuthorized
    case systemLimitReached
    case invalidRequest(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Alarm permission has not been granted."
        case .systemLimitReached:
            return "iOS will not hold any more alarms. Cancel one first."
        case .invalidRequest(let detail):
            return "That alarm could not be built: \(detail)"
        case .underlying(let detail):
            return detail
        }
    }
}

/// Used by tests and SwiftUI previews. Behaves like a system that always says yes and forgets
/// nothing, so reconciliation logic can be exercised by deleting from `ids` directly.
@MainActor
final class InMemoryAlarmScheduler: AlarmScheduling {
    private(set) var ids: Set<UUID> = []
    private(set) var requests: [UUID: AlarmScheduleRequest] = [:]
    var authorized = true
    var failNextSchedule: AlarmSchedulingError?

    func requestAuthorization() async -> Bool { authorized }
    func isAuthorized() async -> Bool { authorized }
    func scheduledAlarmIDs() async -> Set<UUID> { ids }

    func schedule(_ request: AlarmScheduleRequest) async throws {
        if let failure = failNextSchedule {
            failNextSchedule = nil
            throw failure
        }
        guard authorized else { throw AlarmSchedulingError.notAuthorized }
        ids.insert(request.id)
        requests[request.id] = request
    }

    func cancel(id: UUID) async {
        ids.remove(id)
        requests[id] = nil
    }

    /// Simulates the system dropping an alarm — a reboot, a restore, an OS bug.
    func simulateSystemLoss(of id: UUID) {
        ids.remove(id)
    }

    /// Simulates an alarm the app has no record of.
    func simulateOrphan(_ id: UUID) {
        ids.insert(id)
    }
}
