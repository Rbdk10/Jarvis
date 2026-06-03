import Foundation
import Combine

/// Tracks what the fast brain spends on the Anthropic API, so you can watch the running
/// total against your credit.
///
/// The Anthropic key powers exactly ONE thing in this app — the fast brain (`FastBrain`).
/// ElevenLabs (voice) is billed separately, and the mini agent runs on its own Claude
/// plan. So this total IS the complete picture of what this key spends.
///
/// Costs are computed from each response's `usage` block using Claude Haiku 4.5 pricing,
/// and the running total is persisted across launches in UserDefaults.
@MainActor
final class CostMeter: ObservableObject {
    // Claude Haiku 4.5 pricing — US dollars per 1,000,000 tokens.
    // (Haiku 4.5: $1 in / $5 out. Cache write = 1.25× input, cache read = 0.1× input.)
    private static let inputPerM = 1.00
    private static let outputPerM = 5.00
    private static let cacheWritePerM = 1.25
    private static let cacheReadPerM = 0.10

    @Published private(set) var totalCostUSD: Double
    @Published private(set) var lastCallCostUSD: Double = 0
    @Published private(set) var callCount: Int
    @Published private(set) var inputTokens: Int     // full prompt tokens (incl. cache)
    @Published private(set) var outputTokens: Int

    private let defaults = UserDefaults.standard
    private enum Key {
        static let cost = "costMeter.totalCostUSD"
        static let calls = "costMeter.callCount"
        static let inTok = "costMeter.inputTokens"
        static let outTok = "costMeter.outputTokens"
    }

    init() {
        totalCostUSD = defaults.double(forKey: Key.cost)
        callCount = defaults.integer(forKey: Key.calls)
        inputTokens = defaults.integer(forKey: Key.inTok)
        outputTokens = defaults.integer(forKey: Key.outTok)
    }

    /// Record one Anthropic response from its `usage` block. Cache fields are normally 0
    /// for the fast brain (the prompt is below Haiku's 4096-token cache minimum), but
    /// they're priced correctly here so the moment caching ever kicks in it's accounted for.
    func record(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        let cost = Double(input)      / 1_000_000 * Self.inputPerM
                 + Double(output)     / 1_000_000 * Self.outputPerM
                 + Double(cacheWrite) / 1_000_000 * Self.cacheWritePerM
                 + Double(cacheRead)  / 1_000_000 * Self.cacheReadPerM

        lastCallCostUSD = cost
        totalCostUSD += cost
        callCount += 1
        inputTokens += input + cacheWrite + cacheRead
        outputTokens += output

        defaults.set(totalCostUSD, forKey: Key.cost)
        defaults.set(callCount, forKey: Key.calls)
        defaults.set(inputTokens, forKey: Key.inTok)
        defaults.set(outputTokens, forKey: Key.outTok)
    }

    /// Wipe the running total (e.g. when the billing period rolls over).
    func reset() {
        totalCostUSD = 0; lastCallCostUSD = 0; callCount = 0; inputTokens = 0; outputTokens = 0
        [Key.cost, Key.calls, Key.inTok, Key.outTok].forEach { defaults.removeObject(forKey: $0) }
    }

    /// Money formatted to 4 dp so sub-cent fast-brain spend is actually visible.
    static func money(_ usd: Double) -> String { String(format: "$%.4f", usd) }
    var totalText: String { Self.money(totalCostUSD) }
    var lastCallText: String { Self.money(lastCallCostUSD) }
}
