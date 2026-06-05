import SwiftUI

/// The J.A.R.V.I.S. core: the arc-reactor image sits still in the centre while the "orb" —
/// animated HUD rings and orbiting glints — drifts around it. Everything brightens, and the
/// core pulses, with `level` (0...1) while Jarvis speaks; `accent` tints the orb (blue while
/// listening, amber while speaking). Same `OrbView(level:accent:)` interface as before.
struct OrbView: View {
    var level: Float
    var accent: UIColor
    private var l: CGFloat { CGFloat(max(0, min(1, level))) }

    var body: some View {
        // TimelineView(.animation) drives smooth, continuous motion off the clock — so the
        // orb keeps drifting independently of the voice-reactive (level) changes.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                content(t: t, s: min(geo.size.width, geo.size.height))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func content(t: TimeInterval, s: CGFloat) -> some View {
        let coreSide = s * 0.56
        let a = Color(uiColor: accent)
        return ZStack {
            // Soft accent bloom behind the core — swells with the voice level.
            Circle().fill(a)
                .frame(width: coreSide * 0.8, height: coreSide * 0.8)
                .blur(radius: 64)
                .opacity(0.10 + Double(l) * 0.5)

            // The orb: rings + glints drifting around the core (opposite directions).
            ring(s * 0.36, dash: [3, 11], width: 1.3, deg: t * 16, color: a)
            ring(s * 0.42, dash: [1, 18], width: 1.0, deg: -t * 24, color: a)
            glints(radius: s * 0.39, count: 5, deg: t * 12, color: a)

            // The static core image in the centre. `.screen` lets its black backdrop fall
            // away so it reads as floating light rather than a hard square.
            Image("JarvisCore")
                .resizable().scaledToFit()
                .frame(width: coreSide, height: coreSide)
                .blendMode(.screen)
                .brightness(Double(l) * 0.16)
                .scaleEffect(1.0 + l * 0.05)
                .shadow(color: a.opacity(0.5 * Double(l)), radius: 22)
        }
    }

    private func ring(_ radius: CGFloat, dash: [CGFloat], width: CGFloat, deg: Double, color: Color) -> some View {
        Circle()
            .stroke(color.opacity(0.22 + Double(l) * 0.5),
                    style: StrokeStyle(lineWidth: width, dash: dash))
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(deg))
    }

    private func glints(radius: CGFloat, count: Int, deg: Double, color: Color) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(color)
                    .frame(width: 3.5, height: 3.5)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
        .rotationEffect(.degrees(deg))
        .opacity(0.45 + Double(l) * 0.5)
    }
}
