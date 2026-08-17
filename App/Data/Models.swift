import Foundation
import SwiftData

// The rest of the app talks to these names, not to the version namespace. When V2 lands, these
// typealiases move to point at V2 and nothing else in the app has to change.

typealias AppSettings = AssistantSchemaV1.AppSettings
typealias Project = AssistantSchemaV1.Project
typealias AlarmItem = AssistantSchemaV1.AlarmItem
typealias AlarmOccurrence = AssistantSchemaV1.AlarmOccurrence
typealias Conversation = AssistantSchemaV1.Conversation
typealias Message = AssistantSchemaV1.Message
typealias DailyLog = AssistantSchemaV1.DailyLog
typealias Event = AssistantSchemaV1.Event

/// The current schema, and how to get here from every older one.
///
/// There is only one version today, so there are no stages. The plan exists now so that adding
/// V2 is a two-line change rather than a rescue operation.
enum AssistantMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AssistantSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

enum Constants {
    static let defaultProjectName = "Life"
    /// Two alarms inside this window of each other are treated as a collision (requirement 7).
    static let collisionWindow: TimeInterval = 60
    /// How many future occurrences of a non-native recurrence are pre-scheduled. See ARCHITECTURE.md §2.
    static let rollingHorizonCount = 8
    /// Below this, the rules layer hands off to Apple's model (if it can help) or to the fallback form.
    static let ruleConfidenceThreshold = 0.6
}
