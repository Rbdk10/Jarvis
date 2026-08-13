import ActivityKit
import Foundation

/// The Live Activity contract shared between the app (which drives it) and the widget
/// extension (which renders it in the Dynamic Island / Lock Screen).
///
/// `ContentState` is the live, updatable part — Jarvis's current phase and the latest line
/// (what he's saying, or what he heard). The app pushes a new ContentState on every state
/// change so the island tracks him in real time, even while you're in another app.
struct JarvisActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Coarse phase driving the orb colour + label. Kept as a String (not the app's
        /// internal enum) so the widget target doesn't depend on the app's engine code.
        var phase: Phase
        /// The line to show: what Jarvis is saying (speaking), a status (thinking),
        /// "Listening…" (listening), or the last reply (idle linger).
        var line: String
    }

    /// Static title — the wordmark.
    var title: String = "J.A.R.V.I.S"
}

/// Jarvis's coarse state, shared with the widget. Mirrors the app's internal state machine
/// but lives here so both targets can use it.
enum Phase: String, Codable, Hashable {
    case idle, listening, thinking, speaking, error

    /// Short label for the island's trailing/expanded text.
    var label: String {
        switch self {
        case .idle:      return "Ready"
        case .listening: return "Listening"
        case .thinking:  return "Working"
        case .speaking:  return "Speaking"
        case .error:     return "Offline"
        }
    }
}
