import Foundation

/// Reads configuration injected at build time from Secrets.xcconfig → Info.plist.
/// Nothing secret is hard-coded in source.
enum AppConfig {
    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    static var elevenLabsAPIKey: String { string("ELEVENLABS_API_KEY") }
    static var voiceID: String { string("JARVIS_VOICE_ID") }
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
    static let ttsModel = "eleven_multilingual_v2"
    static let sttModel = "scribe_v1"
    static let stability = 0.83
    static let similarity = 0.55
    static let style = 0.0
    static let speed = 0.92
    static let speakerBoost = true
}
