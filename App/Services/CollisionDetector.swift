import Foundation

/// A stored alarm reduced to what collision detection needs, so the check can be tested without
/// a SwiftData context.
struct AlarmSlot: Equatable, Identifiable {
    let id: UUID
    let itemID: UUID
    let title: String
    let projectName: String
    let scheduledAt: Date
}

/// Requirement 7: before creating an alarm, look at what is already scheduled.
///
/// No collision means create it and say so — no confirmation question. A collision means stop and
/// ask, because silently stacking two alarms on the same minute is how one of them gets missed.
enum CollisionDetector {

    static func conflicts(at date: Date,
                          among slots: [AlarmSlot],
                          window: TimeInterval = Constants.collisionWindow,
                          excludingItem itemID: UUID? = nil,
                          excludingOccurrences excluded: Set<UUID> = []) -> [AlarmSlot] {
        slots.filter { slot in
            if let itemID, slot.itemID == itemID { return false }
            if excluded.contains(slot.id) { return false }
            return abs(slot.scheduledAt.timeIntervalSince(date)) < window
        }
        .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Every collision across a batch of proposed times — used when a recurring item is created and
    /// several of its occurrences might land on top of existing alarms.
    static func conflicts(forAny dates: [Date],
                          among slots: [AlarmSlot],
                          window: TimeInterval = Constants.collisionWindow,
                          excludingItem itemID: UUID? = nil) -> [(date: Date, existing: [AlarmSlot])] {
        dates.compactMap { date in
            let found = conflicts(at: date, among: slots, window: window, excludingItem: itemID)
            return found.isEmpty ? nil : (date, found)
        }
    }
}

/// What the user picks when two alarms want the same minute.
enum CollisionResolution: String, Equatable, CaseIterable {
    case keepBoth
    case replaceExisting
    case postponeExisting
    case postponeNew

    var label: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replaceExisting: return "Replace existing"
        case .postponeExisting: return "Postpone existing"
        case .postponeNew: return "Postpone new one"
        }
    }

    /// Both postpone options need a time before anything can happen.
    var needsNewTime: Bool {
        self == .postponeExisting || self == .postponeNew
    }
}
