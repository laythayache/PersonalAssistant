import Foundation
import SwiftData

/// Owns the one `ModelContainer` for the process.
///
/// App Intents fired from an alarm button run in this same process but outside the SwiftUI view
/// tree, so they need a way to reach the store that does not depend on a view having appeared.
@MainActor
enum PersistenceController {

    /// True when the on-disk store could not be opened and an in-memory one is standing in.
    /// The chat screen shows a red banner when this is set — data written now will not survive a
    /// relaunch, and the user has to be told rather than discovering it later.
    private(set) static var isEphemeral = false
    private(set) static var openFailure: String?

    static let container: ModelContainer = {
        let schema = Schema(versionedSchema: AssistantSchemaV1.self)
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema,
                                      migrationPlan: AssistantMigrationPlan.self,
                                      configurations: [onDisk])
        } catch {
            isEphemeral = true
            openFailure = error.localizedDescription
            DebugLog.shared.error("store", "on-disk store failed to open: \(error.localizedDescription)")

            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let fallback = try? ModelContainer(for: schema, configurations: [memory]) {
                return fallback
            }
            // Both failed. There is nothing left to degrade to.
            fatalError("Could not create any model container: \(error)")
        }
    }()

    static func makeContext() -> ModelContext {
        ModelContext(container)
    }

    /// In-memory container for tests and previews.
    static func makeEphemeralContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: AssistantSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
