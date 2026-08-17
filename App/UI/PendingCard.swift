import SwiftUI

/// The one open question, rendered inline above the keyboard.
///
/// Requirement 7 wants collisions resolved with native buttons and as few taps as possible, so
/// nothing here is a modal — the thread stays visible behind it and one tap finishes the job.
struct PendingCard: View {
    let engine: AssistantEngine
    let pending: AssistantEngine.Pending

    @State private var newTime = Date()
    @State private var awaitingTimeFor: CollisionResolution?
    @State private var fallbackTitle = ""
    @State private var fallbackDate = Date()
    @State private var fallbackRecurrence: RecurrenceRule = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch pending {
            case .collision(let prompt): collision(prompt)
            case .disambiguation(let prompt): disambiguation(prompt)
            case .project(let prompt): project(prompt)
            case .fallback(let prompt): fallback(prompt)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.35)))
        .task(id: taskID) { prime() }
    }

    private var taskID: String {
        switch pending {
        case .collision(let p): return "c\(p.proposedDate.timeIntervalSince1970)"
        case .disambiguation(let p): return "d\(p.choices.count)\(p.command.originalText)"
        case .project(let p): return "p\(p.suggestedName)"
        case .fallback(let p): return "f\(p.originalText)"
        }
    }

    private func prime() {
        switch pending {
        case .collision(let prompt):
            newTime = prompt.proposedDate.addingTimeInterval(30 * 60)
            awaitingTimeFor = nil
        case .fallback(let prompt):
            fallbackTitle = prompt.bestGuess.title.isEmpty ? prompt.originalText : prompt.bestGuess.title
            fallbackDate = prompt.bestGuess.scheduledAt ?? Date().addingTimeInterval(3600)
            fallbackRecurrence = prompt.bestGuess.recurrence
        default:
            break
        }
    }

    // MARK: - Collision

    @ViewBuilder
    private func collision(_ prompt: CollisionPrompt) -> some View {
        Label("Already booked", systemImage: "exclamationmark.2")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)

        ForEach(prompt.existing) { slot in
            HStack {
                Image(systemName: "alarm")
                DirectionalText(text: slot.title, font: .subheadline)
                Text(Phrasing.time(slot.scheduledAt))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }

        if let resolution = awaitingTimeFor {
            VStack(alignment: .leading, spacing: 10) {
                Text(resolution == .postponeExisting ? "Move the existing one to" : "Move the new one to")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CompactDateTimePicker(date: $newTime)
                HStack {
                    QuickChip(title: "Confirm", systemImage: "checkmark", isProminent: true) {
                        Task { await engine.resolveCollision(resolution, newTime: newTime) }
                    }
                    QuickChip(title: "Back") { awaitingTimeFor = nil }
                }
            }
        } else {
            FlowRow {
                ForEach(CollisionResolution.allCases, id: \.self) { resolution in
                    QuickChip(title: resolution.label,
                              isProminent: resolution == .keepBoth) {
                        if resolution.needsNewTime {
                            awaitingTimeFor = resolution
                        } else {
                            Task { await engine.resolveCollision(resolution, newTime: nil) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Disambiguation

    @ViewBuilder
    private func disambiguation(_ prompt: DisambiguationPrompt) -> some View {
        Label("Which one?", systemImage: "questionmark.circle")
            .font(.footnote.weight(.semibold))

        ForEach(prompt.choices) { candidate in
            Button {
                Task { await engine.chooseMatch(candidate) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        DirectionalText(text: candidate.title, font: .subheadline)
                        Text(Phrasing.when(candidate.scheduledAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        QuickChip(title: "None of these") { engine.dismissPending() }
    }

    // MARK: - New project

    @ViewBuilder
    private func project(_ prompt: ProjectPrompt) -> some View {
        Text("Make \(prompt.suggestedName) a project?")
            .font(.subheadline.weight(.semibold))
        Text("Its history is then kept together permanently.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            QuickChip(title: "Yes", systemImage: "folder.badge.plus", isProminent: true) {
                Task { await engine.answerProject(create: true) }
            }
            QuickChip(title: "No, put it in Life") {
                Task { await engine.answerProject(create: false) }
            }
        }
    }

    // MARK: - Fallback form

    @ViewBuilder
    private func fallback(_ prompt: FallbackPrompt) -> some View {
        Label("Set this up", systemImage: "hand.tap")
            .font(.footnote.weight(.semibold))
        Text("Your words are saved either way.")
            .font(.caption)
            .foregroundStyle(.secondary)

        TextField("What is it?", text: $fallbackTitle)
            .textFieldStyle(.roundedBorder)
        CompactDateTimePicker(date: $fallbackDate)

        Menu {
            Button("Once") { fallbackRecurrence = .none }
            Button("Every day") { fallbackRecurrence = .weekly(days: RecurrenceRule.allDaysOfWeek) }
            Button("Every weekday") { fallbackRecurrence = .weekly(days: RecurrenceRule.allWeekdays) }
            Button("Weekly on this day") {
                let weekday = Calendar.current.component(.weekday, from: fallbackDate)
                fallbackRecurrence = .weekly(days: [weekday])
            }
        } label: {
            HStack {
                Text("Repeat: \(fallbackRecurrence.describedBriefly)")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline)
        }

        HStack {
            QuickChip(title: "Create", systemImage: "plus", isProminent: true) {
                Task {
                    await engine.applyFallback(title: fallbackTitle,
                                               date: fallbackDate,
                                               recurrence: fallbackRecurrence)
                }
            }
            QuickChip(title: "Just keep the note") { engine.dismissPending() }
        }
    }
}

/// Wraps chips onto new lines. Four collision buttons do not fit across an iPhone in one row, and
/// a horizontal scroll view hides the last option behind an edge.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
