import Foundation

/// Reads configuration injected at build time from Secrets.xcconfig → Info.plist.
/// Nothing secret is hard-coded in source.
enum AppConfig {
    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    static var elevenLabsAPIKey: String { string("ELEVENLABS_API_KEY") }
    /// Powers the on-device "fast brain" (two-speed: instant chit-chat here, real
    /// tasks routed to the agent). Empty → fast brain disabled, everything goes to the agent.
    static var anthropicAPIKey: String { string("ANTHROPIC_API_KEY") }
    /// Low-latency model for the fast brain. Haiku: fast + cheap, ample for chit-chat
    /// and routing. (Was nothing — this is the new in-app brain.)
    static let fastBrainModel = "claude-haiku-4-5-20251001"
    /// Hard ceiling on cumulative fast-brain spend (USD). At/above this the fast brain
    /// switches OFF and every utterance goes to the (free-to-this-key) agent instead, so
    /// the shared Anthropic credit can't be drained. Resetting the cost meter re-enables it.
    static let fastBrainSpendCapUSD = 10.0
    // Public identifier (not a secret) → kept in source so it's in git and everyone
    // gets the same voice. Was ELng4b01d9xlW69WLEz8.
    static let voiceID = "ZGaKTfLiwmY6CuJeS9Tv"
    static var wsToken: String { string("JARVIS_WS_TOKEN") }
    static var wsHost: String {
        let h = string("JARVIS_WS_HOST")
        return h.isEmpty ? "jarvis.ngrok.app" : h
    }

    /// wss://<host>/ws?token=<token>  — built in code so the URL never lives in xcconfig
    /// (xcconfig treats `//` as a comment, so we store only the host there).
    static var socketURL: URL? {
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = wsHost
        comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "token", value: wsToken)]
        return comps.url
    }

    // ElevenLabs voice tuning (matches the Jarvis telegram-voice.env).
    // Low-latency model so Jarvis starts speaking sooner. (Was eleven_multilingual_v2 —
    // richer but slower; switch back if the voice quality is missed.)
    static let ttsModel = "eleven_turbo_v2_5"
    static let sttModel = "scribe_v1"
    static let stability = 0.83
    static let similarity = 0.55
    static let style = 0.0
    static let speed = 0.92
    static let speakerBoost = true
}
