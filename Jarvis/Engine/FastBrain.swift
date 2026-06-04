import Foundation

/// The fast half of Jarvis's two-speed brain.
///
/// Every utterance is first shown to a low-latency Claude model (Haiku) running straight
/// against the Anthropic API. It does one of two things, fast:
///   • answers chit-chat itself (greetings, banter, simple general-knowledge) — so a
///     casual reply lands in well under a second, no round-trip to the mini; or
///   • hands the message off to the full agent (the WebSocket bridge) for anything that
///     needs tools, actions, or live/personal data.
///
/// It keeps a short rolling memory of the conversation so follow-up chit-chat stays
/// coherent. With no API key configured it disables itself and everything goes to the
/// agent (the old behaviour), so the app still works without it.
@MainActor
final class FastBrain {
    /// What to do with an utterance.
    enum Decision {
        case reply(String)   // answered here — speak this now
        case delegate        // needs the agent — send it over the socket
    }

    /// True when a key is present AND spend is under the cap — i.e. the fast brain may run.
    var isEnabled: Bool { !AppConfig.anthropicAPIKey.isEmpty && !isOverSpendCap }

    /// True once cumulative spend has reached the cap. A key is configured but the fast
    /// brain has been switched off to protect the credit; everything routes to the agent.
    var isOverSpendCap: Bool {
        !AppConfig.anthropicAPIKey.isEmpty
            && meter.totalCostUSD >= AppConfig.fastBrainSpendCapUSD
    }

    /// Meters every call's token spend so you can see the running cost against your credit.
    let meter: CostMeter
    init(meter: CostMeter) { self.meter = meter }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Rolling [{role, content}] memory of the spoken conversation (chat turns + a note
    /// for any handed-off task), capped so the request stays small and fast.
    private var history: [[String: String]] = []
    private let maxHistory = 12   // ~6 turns

    private let systemPrompt = """
    You are Jarvis — the voice the user talks to. Think of yourself as the front desk: you \
    greet them, field everything they say, and either answer it yourself or send it through \
    to your backend. That backend (your "agent") is a powerful AI with full access to the \
    user's Mac, files, messages, calendar, code and the web — it does the real work. You and \
    the agent are ONE assistant, called Jarvis. Never imply you're separate things or a \
    different project, and never say you're confused about what this is or "can't" help — you \
    are the front desk for everything the user needs.

    Answer in the Jarvis voice: dry-witted, unflappable, lightly British, calling the user \
    "sir" occasionally (not every line). For each message, decide who answers:

    • route "chat" — you answer it yourself. Conversation, greetings, banter, opinions, \
    clarifications, and questions you can answer confidently from general knowledge. Keep it \
    short and spoken: one to three sentences, no markdown, no lists, no emoji.

    • route "task" — send it through to the agent (leave "say" empty; the agent replies). Use \
    this whenever the user wants something DONE — build, make, change, fix, run, check, send, \
    find, open, schedule — or when answering needs the Mac, files, messages, calendar, the \
    web, current events, or anything personal to the user that you cannot see. Also use it for \
    anything you are not confident you can answer correctly.

    You are NEVER the wrong place, and you can NEVER simply "not do" something: if it isn't \
    yours to answer, it's the agent's. When unsure, route "task" — sending it through is \
    always safe and far better than refusing, guessing, or claiming you can't help. Don't \
    apologise or announce the hand-off; just route it and let the agent take over.

    Reply with ONLY a JSON object and nothing else:
    {"route":"chat","say":"<your spoken reply>"} or {"route":"task","say":""}
    """

    /// Classify (and possibly answer) one utterance. Never throws — any failure
    /// (no key, network, bad response) falls back to `.delegate` so the agent still gets it.
    func decide(_ userText: String) async -> Decision {
        guard isEnabled else { return .delegate }

        var messages = history
        messages.append(["role": "user", "content": userText])

        let body: [String: Any] = [
            "model": AppConfig.fastBrainModel,
            "max_tokens": 300,
            "temperature": 0.5,
            // Mark the (static) system prompt cacheable. NOTE: Haiku 4.5 only caches
            // prefixes ≥ 4096 tokens, and ours is far shorter — so this is a no-op today
            // (you'll see cache tokens stay 0 in the meter). It costs nothing and starts
            // saving automatically if Jarvis's persona/rules ever grow past that floor.
            "system": [["type": "text", "text": systemPrompt,
                        "cache_control": ["type": "ephemeral"]]],
            "messages": messages
        ]

        guard let decoded = await call(body: body) else {
            // Couldn't reach/parse the fast brain — let the agent handle it. Don't poison
            // history with a turn that never resolved.
            return .delegate
        }

        // Record this turn so follow-ups have context.
        history.append(["role": "user", "content": userText])
        switch decoded {
        case .reply(let say):
            history.append(["role": "assistant", "content": say])
        case .delegate:
            history.append(["role": "assistant", "content": "(handed that to the agent)"])
        }
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }

        return decoded
    }

    /// Drop the conversation memory (e.g. on a long gap) — currently unused but cheap to keep.
    func resetMemory() { history.removeAll() }

    // MARK: - Anthropic call

    private func call(body: [String: Any]) async -> Decision? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(AppConfig.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 12

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Meter the spend from this call's usage block, then read the reply.
        recordUsage(obj["usage"] as? [String: Any])
        guard let text = Self.firstText(in: obj) else { return nil }
        return Self.parseDecision(from: text)
    }

    /// Add this response's token usage to the cost meter (Anthropic returns a top-level
    /// `usage` object on every Messages response).
    private func recordUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        meter.record(
            input:      usage["input_tokens"] as? Int ?? 0,
            output:     usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead:  usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    /// Pull the first text block out of an Anthropic Messages response.
    private static func firstText(in obj: [String: Any]) -> String? {
        guard let content = obj["content"] as? [[String: Any]] else { return nil }
        for block in content where (block["type"] as? String) == "text" {
            if let t = block["text"] as? String { return t }
        }
        return nil
    }

    /// Parse the model's `{"route":...,"say":...}` JSON. Tolerates stray prose around it
    /// by extracting the outermost {...}. Defaults to delegating if anything is off.
    private static func parseDecision(from text: String) -> Decision {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return .delegate }
        let jsonSlice = String(text[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .delegate
        }
        let route = (obj["route"] as? String)?.lowercased() ?? "task"
        let say = (obj["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if route == "chat", !say.isEmpty { return .reply(say) }
        return .delegate
    }
}
