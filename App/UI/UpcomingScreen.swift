import SwiftUI
import SwiftData

/// Requirement 13's Upcoming Alarms list.
///
/// Natively repeating alarms are expanded for display only. The store holds one occurrence per
/// series because the system holds one alarm per series — showing four Mondays does not mean four
/// rows exist, and the list says so rather than pretending otherwise.
struct UpcomingScreen: View {
    let engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var postponing: Row?
    @State private var newTime = Date()

    struct Row: Identifiable, Equatable {
        let id: String
        let occurrenceID: UUID
        let date: Date
        let title: String
        let projectName: String
        let recurrence: RecurrenceRule
        let isProjected: Bool
        let isRegistered: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    ContentUnavailableView("Nothing scheduled",
                                           systemImage: "alarm",
                                           description: Text("Ask for something in chat."))
                }
                ForEach(groupedKeys, id: \.self) { key in
                    Section(key) {
                        ForEach(grouped[key] ?? []) { row in
                            rowView(row)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Upcoming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { reload() }
            .sheet(item: $postponing) { row in
                postponeSheet(row)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.date.formatted(.dateTime.hour().minute()))
                    .font(.headline.monospacedDigit())
                if row.recurrence.isRepeating {
                    Text(row.recurrence.describedBriefly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                DirectionalText(text: row.title, font: .body)
                HStack(spacing: 6) {
                    if row.projectName != Constants.defaultProjectName {
                        Text(row.projectName).font(.caption).foregroundStyle(.secondary)
                    }
                    if row.isProjected {
                        Text("repeat").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !row.isRegistered && !row.isProjected {
                        Label("not registered", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .swipeActions(edge: .trailing) {
            if !row.isProjected {
                Button(role: .destructive) {
                    Task {
                        await engine.executor.setStatus(occurrenceID: row.occurrenceID, to: .cancelled)
                        reload()
                    }
                } label: { Label("Cancel", systemImage: "trash") }

                Button {
                    newTime = row.date.addingTimeInterval(3600)
                    postponing = row
                } label: { Label("Postpone", systemImage: "clock.arrow.circlepath") }
                .tint(.purple)
            }
        }
    }

    private func postponeSheet(_ row: Row) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DirectionalText(text: row.title, font: .headline)
                CompactDateTimePicker(date: $newTime)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Postpone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { postponing = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move") {
                        Task {
                            await engine.executor.reschedule(occurrenceID: row.occurrenceID,
                                                             to: newTime,
                                                             reason: "Postponed from Upcoming")
                            postponing = nil
                            reload()
                        }
                    }
                }
            }
        }
        .presentationDetents([.height(260)])
    }

    private var grouped: [String: [Row]] {
        Dictionary(grouping: rows) { row in
            Phrasing.when(row.date).replacingOccurrences(of: " at \(Phrasing.time(row.date))", with: "")
        }
    }

    private var groupedKeys: [String] {
        grouped.keys.sorted { lhs, rhs in
            let l = grouped[lhs]?.first?.date ?? .distantFuture
            let r = grouped[rhs]?.first?.date ?? .distantFuture
            return l < r
        }
    }

    private func reload() {
        rows = engine.projectedUpcoming(limit: 40).enumerated().map { index, entry in
            let isProjected = entry.date != entry.occurrence.scheduledAt
            return Row(id: "\(entry.occurrence.id)-\(index)",
                       occurrenceID: entry.occurrence.id,
                       date: entry.date,
                       title: entry.occurrence.title,
                       projectName: entry.occurrence.projectName,
                       recurrence: entry.occurrence.item?.recurrence ?? .none,
                       isProjected: isProjected,
                       isRegistered: entry.occurrence.isRegisteredWithAlarmKit)
        }
    }
}
