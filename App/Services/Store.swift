import Foundation
import SwiftData

/// Every read and write goes through here.
///
/// Predicates are kept deliberately simple and the finer filtering happens in Swift. This is a
/// single-user app with hundreds of rows, not millions, and a predicate that quietly fails to
/// translate is a far worse outcome than an extra pass over an array.
@MainActor
final class Store {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Settings

    func settings() -> AppSettings {
        let existing = (try? context.fetch(FetchDescriptor<AppSettings>()))?.first
        if let existing { return existing }
        let created = AppSettings()
        context.insert(created)
        save("create settings")
        return created
    }

    // MARK: - Projects

    /// "Life" always exists. Requirement 8 — an item with no project belongs here, never to nothing.
    func defaultProject() -> Project {
        let all = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        if let existing = all.first(where: { $0.isDefault }) { return existing }
        if let byName = all.first(where: { $0.matchKey == Project.matchKey(for: Constants.defaultProjectName) }) {
            byName.isDefault = true
            save("promote Life")
            return byName
        }
        let created = Project(name: Constants.defaultProjectName, isDefault: true)
        context.insert(created)
        context.insert(Event(kind: .projectCreated, detail: "Created default project Life."))
        save("create Life")
        return created
    }

    func allProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func project(named name: String) -> Project? {
        let key = Project.matchKey(for: name)
        guard !key.isEmpty else { return nil }
        return allProjects().first { $0.matchKey == key }
    }

    @discardableResult
    func createProject(named name: String, notes: String = "") -> Project {
        if let existing = project(named: name) { return existing }
        let created = Project(name: name.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes)
        context.insert(created)
        context.insert(Event(kind: .projectCreated, detail: "Created project \(created.name)."))
        save("create project")
        return created
    }

    /// The project a free-text mention points at, or nil. Never invents a project — requirement 8.
    func projectMentioned(in text: String) -> Project? {
        let tokens = Set(Normalizer.normalize(text).tokens.map(\.folded).filter { $0.count >= 2 })
        guard !tokens.isEmpty else { return nil }
        return allProjects().first { project in
            guard !project.isDefault else { return false }
            let key = project.matchKey
            return tokens.contains { token in
                Project.matchKey(for: token) == key
            }
        }
    }

    // MARK: - Items and occurrences

    func allOccurrences() -> [AlarmOccurrence] {
        let descriptor = FetchDescriptor<AlarmOccurrence>(sortBy: [SortDescriptor(\.scheduledAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func occurrence(id: UUID) -> AlarmOccurrence? {
        let descriptor = FetchDescriptor<AlarmOccurrence>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    /// Everything still live: scheduled in the future, or fired and not yet triaged.
    func openOccurrences() -> [AlarmOccurrence] {
        allOccurrences().filter { $0.status.isOpen }
    }

    func upcoming(from now: Date = .now, limit: Int? = nil) -> [AlarmOccurrence] {
        let list = allOccurrences()
            .filter { $0.status == .scheduled && $0.scheduledAt >= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        guard let limit else { return list }
        return Array(list.prefix(limit))
    }

    func occurrences(onDayKey dayKey: String) -> [AlarmOccurrence] {
        allOccurrences()
            .filter { $0.dayKey == dayKey }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Scheduled future alarms reduced to the shape collision detection needs.
    func alarmSlots(from now: Date = .now) -> [AlarmSlot] {
        upcoming(from: now).compactMap { occurrence in
            guard let item = occurrence.item else { return nil }
            return AlarmSlot(id: occurrence.id,
                             itemID: item.id,
                             title: item.title,
                             projectName: item.project?.name ?? Constants.defaultProjectName,
                             scheduledAt: occurrence.scheduledAt)
        }
    }

    /// Candidates for "cancel the Riad thing". Includes recently fired items so a just-missed
    /// alarm can still be postponed.
    ///
    /// The End-of-Day Review is deliberately excluded. It is created by the app rather than asked
    /// for, so letting a vague "cancel that" reach it would be exactly the weak guess requirement 12
    /// forbids — and it would also make every day-wide match ambiguous. It is managed from the
    /// review screen instead.
    func matchCandidates(now: Date = .now, lookBack: TimeInterval = 36 * 3600) -> [MatchCandidate] {
        allOccurrences().compactMap { occurrence in
            guard let item = occurrence.item, item.kind != .dailyReview else { return nil }
            guard occurrence.status.isOpen else { return nil }
            guard occurrence.scheduledAt >= now.addingTimeInterval(-lookBack) else { return nil }
            return MatchCandidate(id: occurrence.id,
                                  itemID: item.id,
                                  title: item.title,
                                  originalText: item.originalText,
                                  projectName: item.project?.name ?? Constants.defaultProjectName,
                                  scheduledAt: occurrence.scheduledAt,
                                  status: occurrence.status)
        }
    }

    func item(id: UUID) -> AlarmItem? {
        let descriptor = FetchDescriptor<AlarmItem>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Chat

    func currentConversation() -> Conversation {
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        if let existing = (try? context.fetch(descriptor))?.first { return existing }
        let created = Conversation()
        context.insert(created)
        save("create conversation")
        return created
    }

    func messages(limit: Int = 500) -> [Message] {
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let recent = (try? context.fetch(descriptor)) ?? []
        return Array(recent.reversed())
    }

    @discardableResult
    func appendMessage(role: MessageRole,
                       text: String,
                       commandJSON: String = "",
                       relatedOccurrenceID: UUID? = nil) -> Message {
        let conversation = currentConversation()
        let message = Message(role: role,
                              text: text,
                              commandJSON: commandJSON,
                              relatedOccurrenceID: relatedOccurrenceID,
                              conversation: conversation)
        context.insert(message)
        save("append message")
        return message
    }

    // MARK: - Daily log

    func dailyLog(for dayKey: String, calendar: Calendar = .current) -> DailyLog {
        let descriptor = FetchDescriptor<DailyLog>(predicate: #Predicate { $0.dayKey == dayKey })
        if let existing = (try? context.fetch(descriptor))?.first { return existing }
        let date = DayKey.startOfDay(for: dayKey, calendar: calendar) ?? .now
        let created = DailyLog(dayKey: dayKey, date: date)
        context.insert(created)
        save("create daily log")
        return created
    }

    // MARK: - Events

    func logEvent(_ kind: EventKind, _ detail: String, itemID: UUID? = nil, occurrenceID: UUID? = nil) {
        context.insert(Event(kind: kind, detail: detail, itemID: itemID, occurrenceID: occurrenceID))
    }

    func events(limit: Int = 200) -> [Event] {
        var descriptor = FetchDescriptor<Event>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Saving

    func save(_ reason: String = "") {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // A failed save is data loss. It is logged loudly rather than swallowed.
            DebugLog.shared.error("store", "save failed (\(reason)): \(error.localizedDescription)")
        }
    }
}
