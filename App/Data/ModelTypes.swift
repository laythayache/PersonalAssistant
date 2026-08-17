import Foundation

// Stored as `String` raw values on the SwiftData models. A new case can then be added without a
// schema migration, which matters because these enums are the ones most likely to grow.

enum AlarmKind: String, Codable, CaseIterable, Sendable {
    case alarm
    case task
    case dailyReview
}

enum OccurrenceStatus: String, Codable, CaseIterable, Sendable {
    /// In the future and registered with AlarmKit.
    case scheduled
    /// Its fire time has passed and it has not been triaged yet. Daily Review picks these up.
    case pendingReview
    case completed
    case missed
    /// Superseded by a later occurrence. `postponedToID` points at the replacement.
    case postponed
    case cancelled

    var isOpen: Bool { self == .scheduled || self == .pendingReview }
    var isHistorical: Bool { !isOpen }

    var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .pendingReview: return "Needs review"
        case .completed: return "Completed"
        case .missed: return "Missed"
        case .postponed: return "Postponed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Append-only audit trail. Nothing in this app deletes; it writes one of these instead.
enum EventKind: String, Codable, Sendable {
    case itemCreated
    case occurrenceScheduled
    case occurrenceRescheduled
    case occurrenceCancelled
    case occurrenceCompleted
    case occurrenceMissed
    case occurrencePostponed
    case occurrenceEdited
    case projectCreated
    case dailyNoteSaved
    case dailyReviewCreated
    case dailyReviewCompleted
    case reconcileRepaired
    case reconcileOrphanRemoved
    case reconcileMarkedPending
    case schedulingFailed
    case authorizationChanged
    case interpretationFallback
}

/// Which layer of the NLU pipeline produced a command. Persisted so a bad interpretation can be
/// traced back to the layer that made it.
enum InterpreterSource: String, Codable, Sendable {
    case rules
    case foundationModel
    /// The user filled in the fallback form by hand.
    case manual
    /// Nothing could be interpreted; the raw text was kept as a note.
    case unparsed
}
