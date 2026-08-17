import Foundation

/// What the executor decided. Anything that needs the user to choose comes back as a prompt with
/// the original command attached, so the choice can be applied without re-parsing the sentence.
enum ExecutionOutcome {
    case reply(String)
    case created(CreatedResult)
    case collision(CollisionPrompt)
    case disambiguation(DisambiguationPrompt)
    case projectQuestion(ProjectPrompt)
    case list(ListResult)
    /// Nothing could be understood. The text is already saved; this offers a prefilled form.
    case fallback(FallbackPrompt)
    case failure(String)

    var replyText: String {
        switch self {
        case .reply(let text): return text
        case .created(let result): return result.reply
        case .collision(let prompt): return prompt.reply
        case .disambiguation(let prompt): return prompt.reply
        case .projectQuestion(let prompt): return prompt.reply
        case .list(let result): return result.reply
        case .fallback(let prompt): return prompt.reply
        case .failure(let text): return text
        }
    }

    var relatedOccurrenceID: UUID? {
        switch self {
        case .created(let result): return result.occurrenceID
        case .list(let result): return result.occurrenceIDs.first
        default: return nil
        }
    }
}

struct CreatedResult {
    let occurrenceID: UUID
    let reply: String
    /// Set when the AM/PM half of the day was inferred rather than stated. The chat shows a single
    /// tap to flip it, instead of asking a question before every alarm.
    let meridiemAlternative: Date?
    /// Set when scheduling with AlarmKit failed. The item is stored either way.
    let schedulingProblem: String?
}

struct CollisionPrompt {
    let command: AssistantCommand
    let proposedDate: Date
    let existing: [AlarmSlot]
    let reply: String
}

struct DisambiguationPrompt {
    let command: AssistantCommand
    let choices: [MatchCandidate]
    let reply: String
}

struct ProjectPrompt {
    let command: AssistantCommand
    let suggestedName: String
    let reply: String
}

struct ListResult {
    let occurrenceIDs: [UUID]
    let reply: String
}

struct FallbackPrompt {
    let originalText: String
    let bestGuess: AssistantCommand
    let reply: String
}
