import Foundation
import Observation
import SwiftData

/// What the chat screen talks to. Owns the pipeline and the one open question, if there is one.
@MainActor
@Observable
final class AssistantEngine {

    enum Pending: Equatable {
        case collision(CollisionPrompt)
        case disambiguation(DisambiguationPrompt)
        case project(ProjectPrompt)
        case fallback(FallbackPrompt)

        static func == (lhs: Pending, rhs: Pending) -> Bool {
            switch (lhs, rhs) {
            case (.collision(let a), .collision(let b)): return a.command == b.command
            case (.disambiguation(let a), .disambiguation(let b)): return a.choices == b.choices
            case (.project(let a), .project(let b)): return a.suggestedName == b.suggestedName
            case (.fallback(let a), .fallback(let b)): return a.originalText == b.originalText
            default: return false
            }
        }
    }

    /// The one-tap AM/PM correction that follows a guessed bare hour.
    struct MeridiemChip: Equatable {
        let occurrenceID: UUID
        let alternative: Date
    }

    let store: Store
    let executor: CommandExecutor
    let reconciler: Reconciler
    let review: DailyReviewService
    private let interpreter: Interpreter
    private let scheduler: AlarmScheduling
    private let calendar: Calendar

    var pending: Pending?
    var meridiemChip: MeridiemChip?
    var isWorking = false
    var authorizationDenied = false
    var lastReconcileSummary: String?

    init(context: ModelContext,
         scheduler: AlarmScheduling = AlarmKitScheduler(),
         calendar: Calendar = .current) {
        self.calendar = calendar
        self.scheduler = scheduler
        let store = Store(context: context)
        self.store = store
        let review = DailyReviewService(store: store, scheduler: scheduler, calendar: calendar)
        self.review = review
        self.executor = CommandExecutor(store: store, scheduler: scheduler, review: review, calendar: calendar)
        self.reconciler = Reconciler(store: store, scheduler: scheduler, review: review, calendar: calendar)
        self.interpreter = Interpreter(calendar: calendar,
                                       defaultReminderHour: store.settings().defaultReminderHour)
    }

    // MARK: - Lifecycle

    /// Permission first, then bring the two worlds back into line. Both happen before the user can
    /// type anything that depends on them.
    func bootstrap() async {
        _ = store.defaultProject()
        let granted = await scheduler.requestAuthorization()
        authorizationDenied = !granted
        store.logEvent(.authorizationChanged, granted ? "Alarm permission granted." : "Alarm permission denied.")
        store.save("bootstrap")
        await refresh()
    }

    func refresh() async {
        let report = await reconciler.reconcile(now: .now)
        authorizationDenied = !report.authorized
        lastReconcileSummary = report.didAnything ? report.summary : nil
        if !report.failures.isEmpty {
            appendAssistant("Some alarms could not be registered with iOS:\n" +
                            report.failures.prefix(3).map { "· \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: - Chat

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The user's words are stored before anything is interpreted. If every layer below fails,
        // the text still exists.
        store.appendMessage(role: .user, text: trimmed)
        pending = nil
        meridiemChip = nil
        isWorking = true
        defer { isWorking = false }

        let command = await interpreter.interpret(trimmed, now: .now)
        let outcome = await executor.execute(command, now: .now)
        apply(outcome, command: command)
    }

    private func apply(_ outcome: ExecutionOutcome, command: AssistantCommand) {
        switch outcome {
        case .collision(let prompt):
            pending = .collision(prompt)
        case .disambiguation(let prompt):
            pending = .disambiguation(prompt)
        case .projectQuestion(let prompt):
            pending = .project(prompt)
        case .fallback(let prompt):
            pending = .fallback(prompt)
        case .created(let result):
            if let alternative = result.meridiemAlternative {
                meridiemChip = MeridiemChip(occurrenceID: result.occurrenceID, alternative: alternative)
            }
        default:
            break
        }

        store.appendMessage(role: .assistant,
                            text: outcome.replyText,
                            commandJSON: command.jsonString,
                            relatedOccurrenceID: outcome.relatedOccurrenceID)
    }

    private func appendAssistant(_ text: String) {
        store.appendMessage(role: .assistant, text: text)
    }

    // MARK: - Answering the one open question

    func resolveCollision(_ resolution: CollisionResolution, newTime: Date?) async {
        guard case .collision(let prompt) = pending else { return }
        pending = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await executor.resolveCollision(prompt, with: resolution, newTime: newTime, now: .now)
        apply(outcome, command: prompt.command)
    }

    func chooseMatch(_ candidate: MatchCandidate) async {
        guard case .disambiguation(let prompt) = pending else { return }
        pending = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await executor.applyDisambiguation(prompt, choice: candidate, now: .now)
        apply(outcome, command: prompt.command)
    }

    func answerProject(create: Bool) async {
        guard case .project(let prompt) = pending else { return }
        pending = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await executor.answerProjectQuestion(prompt, createIt: create, now: .now)
        apply(outcome, command: prompt.command)
    }

    func applyFallback(title: String, date: Date, recurrence: RecurrenceRule) async {
        guard case .fallback(let prompt) = pending else { return }
        pending = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await executor.createManually(title: title,
                                                    date: date,
                                                    recurrence: recurrence,
                                                    projectName: nil,
                                                    originalText: prompt.originalText,
                                                    now: .now)
        apply(outcome, command: prompt.bestGuess)
    }

    func dismissPending() {
        pending = nil
    }

    func flipMeridiem() async {
        guard let chip = meridiemChip else { return }
        meridiemChip = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await executor.flipMeridiem(occurrenceID: chip.occurrenceID, now: .now)
        appendAssistant(outcome.replyText)
    }

    // MARK: - Panels

    func upcoming(limit: Int? = nil) -> [AlarmOccurrence] {
        store.upcoming(from: .now, limit: limit)
    }

    /// Display-only expansion of a natively repeating series, so "every Monday" shows more than one
    /// row without inventing occurrence records that do not correspond to a real system alarm.
    func projectedUpcoming(limit: Int = 20) -> [(date: Date, occurrence: AlarmOccurrence)] {
        let engine = RecurrenceEngine(calendar: calendar)
        var rows: [(Date, AlarmOccurrence)] = []

        for occurrence in store.upcoming(from: .now) {
            rows.append((occurrence.scheduledAt, occurrence))
            guard let item = occurrence.item,
                  item.recurrence.isNativelySupportedByAlarmKit else { continue }
            var cursor = occurrence.scheduledAt
            for _ in 0..<3 {
                guard let next = engine.advance(cursor, by: item.recurrence) else { break }
                rows.append((next, occurrence))
                cursor = next
            }
        }
        return rows.sorted { $0.0 < $1.0 }.prefix(limit).map { (date: $0.0, occurrence: $0.1) }
    }

    func daysNeedingReview() -> [String] {
        review.daysNeedingReview(now: .now)
    }

    func modelStatus() -> String {
        switch interpreter.modelAvailability {
        case .ready: return "Apple on-device model available"
        case .unsupportedLanguage: return "Apple model does not support this language"
        case .modelUnavailable(let reason): return "Apple model unavailable (\(reason))"
        case .frameworkMissing: return "Foundation Models not present on this OS"
        }
    }
}
