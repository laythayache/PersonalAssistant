import SwiftUI
import SwiftData

/// Requirement 8. Projects are created by using the app, not configured up front — this screen is
/// for reading their history and adding context, not for building a taxonomy in advance.
struct ProjectsScreen: View {
    let engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var newProjectName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { project in
                    NavigationLink {
                        ProjectDetail(engine: engine, project: project)
                    } label: {
                        HStack {
                            Image(systemName: project.isDefault ? "house" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                Text("\(project.items.count) item\(project.items.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Add") {
                    HStack {
                        TextField("New project name", text: $newProjectName)
                        Button("Add") {
                            let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            engine.store.createProject(named: name)
                            newProjectName = ""
                        }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ProjectDetail: View {
    let engine: AssistantEngine
    @Bindable var project: Project

    var body: some View {
        Form {
            Section {
                TextField("What this project is about", text: $project.notes, axis: .vertical)
                    .lineLimit(3...10)
                    .onChange(of: project.notes) { _, _ in
                        project.modifiedAt = .now
                        engine.store.save("project notes")
                    }
            } header: {
                Text("Context")
            } footer: {
                Text("Kept permanently and used when matching what you type to this project.")
            }

            Section("History") {
                let occurrences = project.items
                    .flatMap(\.occurrences)
                    .sorted { $0.scheduledAt > $1.scheduledAt }
                if occurrences.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(occurrences) { occurrence in
                    HStack(spacing: 10) {
                        Image(systemName: occurrence.status.symbol)
                            .foregroundStyle(occurrence.status.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            DirectionalText(text: occurrence.title, font: .subheadline)
                            Text("\(Phrasing.when(occurrence.scheduledAt)) · \(occurrence.status.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
