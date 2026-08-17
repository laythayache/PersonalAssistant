import Foundation
import SwiftData

/// Version 1 of the store.
///
/// The models are nested inside the version namespace on purpose. When a V2 arrives that needs a
/// custom migration stage, both versions of a type can coexist and the migration can read one and
/// write the other. Retrofitting that shape later is the painful order, so it is here from the start.
/// `Models.swift` provides the flat typealiases the rest of the app uses.
enum AssistantSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [AppSettings.self,
         Project.self,
         AlarmItem.self,
         AlarmOccurrence.self,
         Conversation.self,
         Message.self,
         DailyLog.self,
         Event.self]
    }

    // MARK: - Settings

    /// Exactly one row. Created on first launch, never deleted.
    @Model
    final class AppSettings {
        @Attribute(.unique) var id: UUID
        /// Nil until onboarding asks. The app never invents this value — requirement 11.
        var endOfDayHour: Int?
        var endOfDayMinute: Int?
        var hasCompletedOnboarding: Bool
        /// Used when a request names a day but no time at all ("remind me tomorrow to call Riad").
        var defaultReminderHour: Int
        var snoozeMinutes: Int
        var createdAt: Date
        var modifiedAt: Date

        init(id: UUID = UUID(),
             endOfDayHour: Int? = nil,
             endOfDayMinute: Int? = nil,
             hasCompletedOnboarding: Bool = false,
             defaultReminderHour: Int = 9,
             snoozeMinutes: Int = 9,
             createdAt: Date = .now,
             modifiedAt: Date = .now) {
            self.id = id
            self.endOfDayHour = endOfDayHour
            self.endOfDayMinute = endOfDayMinute
            self.hasCompletedOnboarding = hasCompletedOnboarding
            self.defaultReminderHour = defaultReminderHour
            self.snoozeMinutes = snoozeMinutes
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }

        var endOfDayIsConfigured: Bool { endOfDayHour != nil && endOfDayMinute != nil }
    }

    // MARK: - Projects

    @Model
    final class Project {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Lower-cased, punctuation-free. Matching happens against this, display uses `name`.
        var matchKey: String
        /// True only for "Life". Guaranteed to exist, cannot be deleted.
        var isDefault: Bool
        /// Free text the user has told the assistant about this project. Never auto-generated.
        var notes: String
        var createdAt: Date
        var modifiedAt: Date

        @Relationship(deleteRule: .nullify, inverse: \AlarmItem.project)
        var items: [AlarmItem]

        init(id: UUID = UUID(),
             name: String,
             isDefault: Bool = false,
             notes: String = "",
             createdAt: Date = .now,
             modifiedAt: Date = .now) {
            self.id = id
            self.name = name
            self.matchKey = Project.matchKey(for: name)
            self.isDefault = isDefault
            self.notes = notes
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.items = []
        }

        static func matchKey(for name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        }
    }

    // MARK: - Items and occurrences

    /// One thing the user asked for. Recurring items have many occurrences; one-shot items have one.
    @Model
    final class AlarmItem {
        @Attribute(.unique) var id: UUID
        var title: String
        /// Exactly what the user typed, byte for byte. Never rewritten — requirement 4 and 9.
        var originalText: String
        /// JSON of the `AssistantCommand` that produced this item, so a wrong reading is traceable.
        var interpretationJSON: String
        var kindRaw: String
        var recurrenceJSON: String?
        var isCancelled: Bool
        var cancelledAt: Date?
        var createdAt: Date
        var modifiedAt: Date
        var project: Project?

        @Relationship(deleteRule: .cascade, inverse: \AlarmOccurrence.item)
        var occurrences: [AlarmOccurrence]

        init(id: UUID = UUID(),
             title: String,
             originalText: String,
             interpretationJSON: String = "",
             kind: AlarmKind = .alarm,
             recurrence: RecurrenceRule = .none,
             project: Project? = nil,
             createdAt: Date = .now) {
            self.id = id
            self.title = title
            self.originalText = originalText
            self.interpretationJSON = interpretationJSON
            self.kindRaw = kind.rawValue
            self.recurrenceJSON = recurrence.jsonString
            self.isCancelled = false
            self.cancelledAt = nil
            self.createdAt = createdAt
            self.modifiedAt = createdAt
            self.project = project
            self.occurrences = []
        }

        var kind: AlarmKind {
            get { AlarmKind(rawValue: kindRaw) ?? .alarm }
            set { kindRaw = newValue.rawValue }
        }

        var recurrence: RecurrenceRule {
            get { RecurrenceRule.fromJSON(recurrenceJSON) }
            set { recurrenceJSON = newValue.jsonString }
        }
    }

    /// One concrete fire time.
    ///
    /// For one-shot alarms and for each step of a rolling recurrence, `alarmKitID == id`: one
    /// occurrence, one system alarm, same UUID, which is what makes a repair idempotent instead of
    /// a duplicate. For a natively repeating weekly alarm there is only ever *one* system alarm for
    /// the whole series, so every occurrence in that series shares its `alarmKitID`.
    @Model
    final class AlarmOccurrence {
        @Attribute(.unique) var id: UUID
        var alarmKitID: UUID?
        var scheduledAt: Date
        /// Never changed after creation, so a postponement chain can always be read back.
        var originalScheduledAt: Date
        var statusRaw: String
        var statusChangedAt: Date
        /// True once AlarmKit has confirmed the registration.
        var isRegisteredWithAlarmKit: Bool
        /// "yyyy-MM-dd" in the local calendar. Indexed lookup key for Daily Review.
        var dayKey: String
        /// Set on the old occurrence when it is postponed.
        var postponedToID: UUID?
        /// Set on the new occurrence created by a postponement.
        var postponedFromID: UUID?
        var createdAt: Date
        var item: AlarmItem?

        init(id: UUID = UUID(),
             alarmKitID: UUID? = nil,
             scheduledAt: Date,
             status: OccurrenceStatus = .scheduled,
             dayKey: String,
             item: AlarmItem? = nil,
             createdAt: Date = .now) {
            self.id = id
            self.alarmKitID = alarmKitID ?? id
            self.scheduledAt = scheduledAt
            self.originalScheduledAt = scheduledAt
            self.statusRaw = status.rawValue
            self.statusChangedAt = createdAt
            self.isRegisteredWithAlarmKit = false
            self.dayKey = dayKey
            self.postponedToID = nil
            self.postponedFromID = nil
            self.createdAt = createdAt
            self.item = item
        }

        var status: OccurrenceStatus {
            get { OccurrenceStatus(rawValue: statusRaw) ?? .scheduled }
            set {
                statusRaw = newValue.rawValue
                statusChangedAt = .now
            }
        }

        var title: String { item?.title ?? "Alarm" }
        var projectName: String { item?.project?.name ?? Constants.defaultProjectName }
        var kind: AlarmKind { item?.kind ?? .alarm }

        /// True when this occurrence is one step of a series the system repeats by itself, so the
        /// reconciler must not try to register it separately.
        var belongsToNativeSeries: Bool {
            item?.recurrence.isNativelySupportedByAlarmKit ?? false
        }
    }

    // MARK: - Chat

    @Model
    final class Conversation {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var title: String

        @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
        var messages: [Message]

        init(id: UUID = UUID(), startedAt: Date = .now, title: String = "Chat") {
            self.id = id
            self.startedAt = startedAt
            self.title = title
            self.messages = []
        }
    }

    @Model
    final class Message {
        @Attribute(.unique) var id: UUID
        var roleRaw: String
        var text: String
        var createdAt: Date
        /// For user messages: the JSON of the command the text was interpreted into. Empty when
        /// nothing was interpreted — the text is still here either way.
        var commandJSON: String
        /// Occurrence this message created or acted on, if any. Lets a bubble deep-link.
        var relatedOccurrenceID: UUID?
        var conversation: Conversation?

        init(id: UUID = UUID(),
             role: MessageRole,
             text: String,
             createdAt: Date = .now,
             commandJSON: String = "",
             relatedOccurrenceID: UUID? = nil,
             conversation: Conversation? = nil) {
            self.id = id
            self.roleRaw = role.rawValue
            self.text = text
            self.createdAt = createdAt
            self.commandJSON = commandJSON
            self.relatedOccurrenceID = relatedOccurrenceID
            self.conversation = conversation
        }

        var role: MessageRole {
            get { MessageRole(rawValue: roleRaw) ?? .assistant }
            set { roleRaw = newValue.rawValue }
        }
    }

    // MARK: - Daily log

    @Model
    final class DailyLog {
        @Attribute(.unique) var dayKey: String
        var id: UUID
        var date: Date
        /// "Unplanned events / Notes about today". Free text, kept forever.
        var notes: String
        var reviewCompletedAt: Date?
        /// The End-of-Day Review alarm occurrence for this day, if one was needed.
        var reviewOccurrenceID: UUID?
        var createdAt: Date
        var modifiedAt: Date

        init(id: UUID = UUID(),
             dayKey: String,
             date: Date,
             notes: String = "",
             createdAt: Date = .now) {
            self.id = id
            self.dayKey = dayKey
            self.date = date
            self.notes = notes
            self.reviewCompletedAt = nil
            self.reviewOccurrenceID = nil
            self.createdAt = createdAt
            self.modifiedAt = createdAt
        }
    }

    // MARK: - Audit trail

    @Model
    final class Event {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var at: Date
        var detail: String
        var itemID: UUID?
        var occurrenceID: UUID?

        init(id: UUID = UUID(),
             kind: EventKind,
             at: Date = .now,
             detail: String,
             itemID: UUID? = nil,
             occurrenceID: UUID? = nil) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.at = at
            self.detail = detail
            self.itemID = itemID
            self.occurrenceID = occurrenceID
        }

        var kind: EventKind { EventKind(rawValue: kindRaw) ?? .schedulingFailed }
    }
}
