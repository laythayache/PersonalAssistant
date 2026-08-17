import SwiftUI

/// Requirement 11's review. Every alarm from that day, one tap each, plus the free-text notes.
struct DailyReviewScreen: View {
    let engine: AssistantEngine
    let dayKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var notes = ""
    @State private var postponing: Row?
    @State private var newTime = Date()
    @State private var isSaving = false

    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let time: Date
        let projectName: String
        var status: OccurrenceStatus
        let wasPostponedFrom: Bool
    }

    private var reviewable: [Row] {
        rows.filter { $0.status != .cancelled }
    }

    var body: some View {
        NavigationStack {
            Form {
                if reviewable.isEmpty {
                    Section {
                        ContentUnavailableView("Nothing to review",
                                               systemImage: "checkmark.circle",
                                               description: Text("No alarms were set for this day."))
                    }
                }

                if !reviewable.isEmpty {
                    Section("What happened") {
                        ForEach($rows) { $row in
                            if row.status != .cancelled {
                                reviewRow($row)
                            }
                        }
                    }
                }

                Section {
                    TextField("Anything unplanned, or worth remembering",
                              text: $notes, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Unplanned events / notes about today")
                } footer: {
                    Text("Kept permanently with this day. Nothing is summarised away.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
            .task { reload() }
            .sheet(item: $postponing) { row in
                postponeSheet(row)
            }
        }
    }

    private var title: String {
        guard let date = DayKey.startOfDay(for: dayKey) else { return "Review" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func reviewRow(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.wrappedValue.time.formatted(.dateTime.hour().minute()))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                DirectionalText(text: row.wrappedValue.title, font: .body)
            }
            if row.wrappedValue.wasPostponedFrom {
                Label("moved from an earlier time", systemImage: "arrow.uturn.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: row.status) {
                Text("Done").tag(OccurrenceStatus.completed)
                Text("Missed").tag(OccurrenceStatus.missed)
                Text("Postponed").tag(OccurrenceStatus.postponed)
            }
            .pickerStyle(.segmented)
            .onChange(of: row.wrappedValue.status) { _, status in
                // Postponed is meaningless without a new time, so ask straight away.
                if status == .postponed {
                    newTime = Calendar.current.date(byAdding: .day, value: 1, to: row.wrappedValue.time)
                        ?? row.wrappedValue.time
                    postponing = row.wrappedValue
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func postponeSheet(_ row: Row) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DirectionalText(text: row.title, font: .headline)
                Text("A new alarm is created. This one stays in history as postponed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CompactDateTimePicker(date: $newTime)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Postpone to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        // Requirement: a postponement requires a time. Undo the segment instead of
                        // leaving a row marked postponed with nowhere to go.
                        revert(row.id)
                        postponing = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move") {
                        Task {
                            await engine.executor.reschedule(occurrenceID: row.id,
                                                             to: newTime,
                                                             reason: "Postponed in daily review")
                            postponing = nil
                            reload()
                        }
                    }
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    private func revert(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = engine.store.occurrence(id: id)?.status ?? .pendingReview
    }

    private func reload() {
        let occurrences = engine.store.occurrences(onDayKey: dayKey)
            .filter { $0.kind != .dailyReview }
        rows = occurrences.map { occurrence in
            Row(id: occurrence.id,
                title: occurrence.title,
                time: occurrence.scheduledAt,
                projectName: occurrence.projectName,
                status: occurrence.status == .scheduled || occurrence.status == .pendingReview
                    ? .pendingReview : occurrence.status,
                wasPostponedFrom: occurrence.postponedFromID != nil)
        }
        notes = engine.store.dailyLog(for: dayKey).notes
    }

    private func save() {
        isSaving = true
        Task {
            for row in rows where row.status == .completed || row.status == .missed {
                await engine.executor.setStatus(occurrenceID: row.id, to: row.status)
            }
            engine.review.completeReview(dayKey: dayKey, notes: notes)
            await engine.refresh()
            isSaving = false
            dismiss()
        }
    }
}
