import Foundation
import os

/// Local-only log. Requirement 20 asks for meaningful failures to be recorded for debugging; this
/// writes them to Application Support and keeps the tail in memory for the in-app Diagnostics screen.
/// Nothing here is ever transmitted.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let category: String
        let message: String
    }

    @Published private(set) var recent: [Entry] = []

    private let logger = Logger(subsystem: "com.laythayache.PersonalAssistant", category: "assistant")
    private let fileURL: URL?
    private let maxInMemory = 300

    private init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        fileURL = base?.appendingPathComponent("assistant.log")
    }

    func log(_ category: String, _ message: String) {
        let entry = Entry(at: .now, category: category, message: message)
        recent.append(entry)
        if recent.count > maxInMemory { recent.removeFirst(recent.count - maxInMemory) }
        logger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        appendToFile(entry)
    }

    func error(_ category: String, _ message: String) {
        log(category, "ERROR " + message)
    }

    private func appendToFile(_ entry: Entry) {
        guard let fileURL else { return }
        let stamp = ISO8601DateFormatter().string(from: entry.at)
        let line = "\(stamp) [\(entry.category)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func exportText() -> String {
        recent.map { entry in
            let stamp = entry.at.formatted(date: .abbreviated, time: .standard)
            return "\(stamp) [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
