import SwiftUI

/// The J.A.R.V.I.S. core — the arc-reactor HUD image, kept alive: it breathes gently at
/// rest, and pulses + brightens with `level` (0...1) while Jarvis speaks. A soft bloom
/// behind it takes the `accent` tint (blue while listening, amber while speaking).
///
/// Same `init(level:accent:)` interface as the old SceneKit orb, so it's a drop-in.
struct OrbView: View {
    var level: Float
    var accent: UIColor

    @State private var breathe = false
    private var l: CGFloat { CGFloat(max(0, min(1, level))) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.94
            ZStack {
                // Accent bloom behind the core — swells with the voice level.
                Circle()
                    .fill(Color(uiColor: accent))
                    .frame(width: side * 0.6, height: side * 0.6)
                    .blur(radius: 70)
                    .opacity(0.10 + Double(l) * 0.55)

                // The core image. `.screen` lets its black backdrop fall away so it reads
                // as glowing light on our dark background rather than a hard square.
                Image("JarvisCore")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .blendMode(.screen)
                    .brightness(Double(l) * 0.16)
                    .scaleEffect((breathe ? 1.012 : 0.992) + l * 0.06)
                    .shadow(color: Color(uiColor: accent).opacity(0.55 * Double(l)), radius: 26)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.10), value: level)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
