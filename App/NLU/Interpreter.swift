import Foundation

@MainActor
protocol Interpreting {
    func interpret(_ text: String, now: Date) async -> AssistantCommand
}

/// Runs the three layers in order and reports which one answered.
///
/// The contract that matters: this never returns nil and never throws. Whatever happens, the user's
/// text comes back attached to a command — worst case a `.saveNote` with `source == .unparsed`,
/// which the chat turns into a one-tap "make this an alarm" form. Requirement 17: text is never lost.
@MainActor
final class Interpreter: Interpreting {

    private let rules: RuleParser
    private let foundationModel: FoundationModelInterpreter
    private let threshold: Double

    init(calendar: Calendar = .current,
         defaultReminderHour: Int = 9,
         threshold: Double = Constants.ruleConfidenceThreshold) {
        self.rules = RuleParser(calendar: calendar, defaultReminderHour: defaultReminderHour)
        self.foundationModel = FoundationModelInterpreter(calendar: calendar,
                                                          defaultReminderHour: defaultReminderHour)
        self.threshold = threshold
    }

    /// Reported on the diagnostics screen so it is obvious which layer is actually doing the work.
    var modelAvailability: FoundationModelInterpreter.Availability {
        foundationModel.availability
    }

    func interpret(_ text: String, now: Date = .now) async -> AssistantCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var empty = AssistantCommand()
            empty.originalText = text
            empty.source = .unparsed
            return empty
        }

        let normalized = Normalizer.normalize(trimmed)
        let ruleResult = rules.parse(trimmed, now: now)

        if ruleResult.confidence >= threshold {
            return ruleResult
        }

        // The grammar was unsure. Ask Apple's model — but only if it can actually read this.
        if foundationModel.canHandle(normalized) {
            let started = Date()
            if let modelResult = await foundationModel.interpret(trimmed, normalized: normalized, now: now) {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                DebugLog.shared.log("nlu", "on-device model answered in \(elapsed)ms, confidence \(String(format: "%.2f", modelResult.confidence))")
                if modelResult.confidence > ruleResult.confidence {
                    return modelResult
                }
            }
        } else {
            DebugLog.shared.log("nlu", "on-device model skipped (script: \(normalized.script.rawValue), availability: \(foundationModel.availability))")
        }

        // Neither layer was confident. Hand back the best reading marked as unparsed so the chat
        // shows the fallback form instead of quietly creating something wrong.
        var fallback = ruleResult
        fallback.source = .unparsed
        if fallback.action != .saveNote {
            fallback.clarificationNeeded = "I am not sure I read that correctly."
        }
        return fallback
    }
}
