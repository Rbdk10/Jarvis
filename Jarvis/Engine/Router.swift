import Foundation

/// Tier-0 routing: cheap, local, ZERO-network heuristics that decide the obvious
/// cases before the fast brain is even called.
///
/// Conservative by design. It only short-circuits on strong signals; anything
/// ambiguous returns `nil` and falls through to the grounded fast brain (Tier 1),
/// which will itself escalate to the agent if it can't answer. That means the
/// heuristic can never produce a *wrong* answer — at worst it sends a
/// fast-answerable turn to the agent (slower, but covered by the instant filler).
enum Router {
    /// True when the utterance is clearly a job for the agent — an action the user
    /// wants *done*, or live/external data the on-device brain cannot hold. Lets the
    /// router skip the fast-brain round-trip and go straight to the agent.
    static func looksLikeAgentTask(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Strong action verbs at the START of the utterance = "do something".
        let actionStarts = [
            "build ", "make ", "create ", "fix ", "change ", "update ", "edit ",
            "run ", "open ", "close ", "send ", "email ", "message ", "text ",
            "schedule ", "remind ", "book ", "cancel ", "delete ", "remove ",
            "deploy ", "push ", "commit ", "install ", "search ", "find ",
            "look up ", "pull up ", "set up ", "turn on ", "turn off ",
        ]
        if actionStarts.contains(where: { t.hasPrefix($0) }) { return true }

        // Live / external data the digest can't contain.
        let liveMarkers = [
            "weather", "the news", "traffic", "right now", "latest",
            "today's", "current price", "stock price", "the score",
        ]
        if liveMarkers.contains(where: { t.contains($0) }) { return true }

        return false
    }
}
