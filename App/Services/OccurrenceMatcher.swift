import Foundation

struct MatchCandidate: Equatable, Identifiable {
    let id: UUID
    let itemID: UUID
    let title: String
    /// The words the user originally used for this item. "Cancel the Riad thing" should match an
    /// alarm titled "etsel b Riad" even though the title was never in English.
    let originalText: String
    let projectName: String
    let scheduledAt: Date
    let status: OccurrenceStatus
}

/// Requirement 12: act on one obvious match, offer a choice when there are several, and never
/// guess. The gap between the best and second-best score is what decides "obvious".
enum OccurrenceMatcher {

    struct Scored: Equatable {
        let candidate: MatchCandidate
        let score: Double
    }

    enum Decision: Equatable {
        case none
        case unique(MatchCandidate)
        case ambiguous([MatchCandidate])
    }

    /// Words that carry no identifying power, so they are not allowed to create a match on their own.
    private static let ignoredQueryTokens: Set<String> = [
        "the", "a", "an", "my", "me", "that", "this", "thing", "alarm", "alarms",
        "reminder", "one", "it", "منبه", "موعد", "هاد", "هاي", "هيدا", "شي"
    ]

    static func rank(candidates: [MatchCandidate],
                     query: String?,
                     targetAt: Date?,
                     targetHasClock: Bool,
                     now: Date = .now,
                     calendar: Calendar = .current) -> [Scored] {

        let queryTokens = meaningfulTokens(query)

        return candidates.map { candidate in
            var score = 0.0

            if !queryTokens.isEmpty {
                let haystack = meaningfulTokens(candidate.title + " " + candidate.originalText
                                                + " " + candidate.projectName)
                let hits = queryTokens.filter { token in
                    haystack.contains { $0 == token || ($0.count > 3 && $0.hasPrefix(token)) || (token.count > 3 && token.hasPrefix($0)) }
                }
                score += 0.6 * (Double(hits.count) / Double(queryTokens.count))
            }

            if let targetAt {
                let sameDay = calendar.isDate(candidate.scheduledAt, inSameDayAs: targetAt)
                if targetHasClock {
                    let delta = abs(candidate.scheduledAt.timeIntervalSince(targetAt))
                    if delta < 30 * 60 { score += 0.5 }
                    else if sameDay { score += 0.15 }
                } else if sameDay {
                    // A day on its own must clear the viability floor: "أجّل موعد بكرا للجمعة"
                    // identifies the alarm being moved by nothing except "tomorrow".
                    score += 0.45
                }
            }

            return Scored(candidate: candidate, score: min(score, 1.0))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 { return lhs.score > rhs.score }
            // Same score: the one happening soonest is the one a person means.
            return abs(lhs.candidate.scheduledAt.timeIntervalSince(now))
                 < abs(rhs.candidate.scheduledAt.timeIntervalSince(now))
        }
    }

    static func decide(_ ranked: [Scored], maximumChoices: Int = 5) -> Decision {
        let viable = ranked.filter { $0.score >= 0.35 }
        guard let best = viable.first else { return .none }

        // Nothing else matched at all. A weak-but-only match is not a guess between alternatives.
        if viable.count == 1 && best.score >= 0.4 {
            return .unique(best.candidate)
        }

        let runnerUp = viable.dropFirst().first?.score ?? 0
        // Strong on its own *and* clearly ahead of the next one. Either condition alone is how the
        // wrong alarm gets cancelled.
        if best.score >= 0.6 && (best.score - runnerUp) >= 0.25 {
            return .unique(best.candidate)
        }
        return .ambiguous(Array(viable.prefix(maximumChoices)).map(\.candidate))
    }

    private static func meaningfulTokens(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return Normalizer.normalize(text).tokens
            .map(\.folded)
            .filter { $0.count >= 2 && !ignoredQueryTokens.contains($0) }
    }
}
