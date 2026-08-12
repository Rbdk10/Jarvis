import Foundation

/// Minimal read client for the Jarvis memory DB (Supabase REST).
///
/// Phase 1 (digest only): fetches the `state` table — the compact, slow-changing
/// "digest" of the user's world — so the on-device fast brain can talk about real
/// things instead of guessing. Personal tables (memories/messages) stay locked to
/// this publishable key by Row-Level Security; they arrive with owner auth later.
///
/// Every call fails soft: on any error it returns empty, and the fast brain simply
/// runs ungrounded (its old behaviour) rather than breaking.
enum SupabaseService {
    struct StateRow: Decodable {
        let slug: String
        let title: String
        let body: String
    }

    /// Fetch the digest rows (`state` where include_in_digest = true), ordered.
    static func fetchDigest() async -> [StateRow] {
        guard let base = AppConfig.supabaseURL, !AppConfig.supabaseKey.isEmpty else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("rest/v1/state"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "select", value: "slug,title,body,sort_order"),
            URLQueryItem(name: "include_in_digest", value: "eq.true"),
            URLQueryItem(name: "order", value: "sort_order.asc"),
        ]
        guard let url = comps?.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue(AppConfig.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(AppConfig.supabaseKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([StateRow].self, from: data) else {
            return []
        }
        return rows
    }

    /// Assemble digest rows into one text block for the fast brain's system prompt.
    static func digestText(from rows: [StateRow]) -> String {
        rows.map { "### \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    // MARK: - Telemetry (fire-and-forget)

    /// Record how one turn routed, so the dispatcher can be tuned from real usage
    /// (Phase 6). NEVER blocks the response and ignores every error — it's launched
    /// detached. Writes are INSERT-only for the publishable key (RLS), so this can't
    /// read anything back; read the log with the service role from Slim.
    static func logTurn(utterance: String, tier: String, model: String?,
                        reason: String, escalated: Bool, latencyMs: Int?) {
        guard let base = AppConfig.supabaseURL, !AppConfig.supabaseKey.isEmpty else { return }
        var row: [String: Any] = [
            "role": "user",
            "content": utterance,
            "tier": tier,
            "route_reason": reason,
            "escalated": escalated,
        ]
        if let model { row["model"] = model }
        if let latencyMs { row["latency_ms"] = latencyMs }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: row) else { return }

        var req = URLRequest(url: base.appendingPathComponent("rest/v1/messages"))
        req.httpMethod = "POST"
        req.setValue(AppConfig.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(AppConfig.supabaseKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 8

        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }
}
