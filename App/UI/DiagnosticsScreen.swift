import SwiftUI
import UIKit

/// Requirement 20 asks for meaningful failures to be logged locally. This is where to read them
/// without a Mac attached — which matters, because the alarm that did not ring is the one you want
/// to investigate on the phone, at the time.
struct DiagnosticsScreen: View {
    let engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DebugLog.Entry] = []
    @State private var reconcileResult: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Language understanding") {
                    LabeledContent("Rules layer", value: "always on, offline")
                    LabeledContent("Apple model", value: engine.modelStatus())
                    Text("Arabic and Arabizi are handled by the rules layer. Apple's on-device model does not list Arabic among its supported languages, so it is never asked to read it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Storage") {
                    LabeledContent("Mode", value: PersistenceController.isEphemeral ? "IN MEMORY — not saved" : "on disk")
                    if let failure = PersistenceController.openFailure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent("Alarms scheduled", value: "\(engine.upcoming().count)")
                    LabeledContent("Projects", value: "\(engine.store.allProjects().count)")
                }

                Section("Alarms") {
                    LabeledContent("Permission", value: engine.authorizationDenied ? "denied" : "granted")
                    Button("Reconcile now") {
                        Task {
                            let report = await engine.reconciler.reconcile()
                            reconcileResult = report.summary
                        }
                    }
                    if let reconcileResult {
                        Text(reconcileResult).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Recent events") {
                    ForEach(engine.store.events(limit: 40)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.rawValue).font(.caption.weight(.semibold))
                            Text(event.detail).font(.caption2).foregroundStyle(.secondary)
                            Text(event.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Log") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(entry.category)] \(entry.message)")
                                .font(.caption2.monospaced())
                            Text(entry.at.formatted(date: .omitted, time: .standard))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Button("Copy log") {
                        UIPasteboard.general.string = DebugLog.shared.exportText()
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { entries = Array(DebugLog.shared.recent.suffix(60).reversed()) }
            .refreshable { entries = Array(DebugLog.shared.recent.suffix(60).reversed()) }
        }
    }
}
