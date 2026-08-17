import Foundation

#if canImport(AlarmKit)
import AlarmKit
#endif

/// Travels inside every AlarmKit alarm this app schedules, and is read back by the Live Activity
/// in the widget extension. It is the only type shared between the app and the widget targets,
/// which is why it deliberately carries `String`s rather than the app's own enums — the widget
/// should not need to link the app's model layer to draw an alert.
struct AssistantAlarmMetadata: Codable, Hashable, Sendable {
    /// Matches `AlarmOccurrence.id` in the store, and the AlarmKit alarm ID. One value, three places.
    var occurrenceID: UUID
    var itemID: UUID
    var title: String
    var projectName: String
    /// `AlarmKind.rawValue`.
    var kind: String

    init(occurrenceID: UUID = UUID(),
         itemID: UUID = UUID(),
         title: String = "",
         projectName: String = "Life",
         kind: String = "alarm") {
        self.occurrenceID = occurrenceID
        self.itemID = itemID
        self.title = title
        self.projectName = projectName
        self.kind = kind
    }

    /// True when this alarm is the End-of-Day Review, which the Live Activity styles differently
    /// and which deep-links into the review screen rather than just stopping.
    var isDailyReview: Bool { kind == "dailyReview" }
}

#if canImport(AlarmKit)
extension AssistantAlarmMetadata: AlarmMetadata {}
#endif
