import ActivityKit
import WidgetKit
import SwiftUI

/// Jarvis in the Dynamic Island + Lock Screen. Renders the live `ContentState` the app pushes
/// as Jarvis listens / works / speaks, so he's present even while you're in another app.
struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(title: context.attributes.title, state: context.state)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbDot(phase: context.state.phase).frame(width: 34, height: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("J.A.R.V.I.S")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(2).foregroundStyle(.white.opacity(0.85))
                        Text(context.state.phase.label.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(phaseTint(context.state.phase))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.line)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                OrbDot(phase: context.state.phase).frame(width: 20, height: 20)
            } compactTrailing: {
                Text(context.state.phase.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(phaseTint(context.state.phase))
                    .lineLimit(1)
            } minimal: {
                OrbDot(phase: context.state.phase).frame(width: 20, height: 20)
            }
            .widgetURL(URL(string: "jarvis://open"))
            .keylineTint(phaseTint(context.state.phase))
        }
    }
}

/// The glowing dot that stands in for the orb — blue while listening/working, amber while
/// speaking, dim when idle.
private struct OrbDot: View {
    let phase: Phase
    var body: some View {
        ZStack {
            Circle().fill(phaseTint(phase).opacity(0.22))
            Circle().fill(phaseTint(phase).opacity(0.9))
                .padding(phase == .speaking ? 3 : 5)
                .shadow(color: phaseTint(phase).opacity(0.8), radius: 4)
        }
    }
}

private struct LockScreenView: View {
    let title: String
    let state: JarvisActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            OrbDot(phase: state.phase).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tracking(3).foregroundStyle(.white.opacity(0.9))
                    Text(state.phase.label.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(phaseTint(state.phase))
                }
                Text(state.line)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

private func phaseTint(_ phase: Phase) -> Color {
    switch phase {
    case .speaking: return Color(red: 1.0, green: 0.55, blue: 0.15)   // amber
    case .error:    return Color(red: 1.0, green: 0.35, blue: 0.32)   // red
    default:        return Color(red: 0.30, green: 0.66, blue: 1.0)    // blue
    }
}
