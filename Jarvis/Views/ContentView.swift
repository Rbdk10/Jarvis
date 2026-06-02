import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: JarvisViewModel

    private var accent: UIColor {
        switch vm.state {
        case .listening: return UIColor(red: 0.20, green: 0.75, blue: 1.00, alpha: 1) // blue
        case .speaking:  return UIColor(red: 1.00, green: 0.62, blue: 0.23, alpha: 1) // amber
        case .thinking:  return UIColor(red: 0.55, green: 0.50, blue: 1.00, alpha: 1) // violet
        case .error:     return UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1) // red
        case .idle:      return UIColor(red: 0.30, green: 0.70, blue: 1.00, alpha: 1) // cyan
        }
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(white: 0.06), .black],
                           center: .center, startRadius: 5, endRadius: 500)
                .ignoresSafeArea()

            OrbView(level: vm.level, accent: accent)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()
                Text("J.A.R.V.I.S")
                    .font(.system(size: 26, weight: .light, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(.white.opacity(0.85))
                Text(vm.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 6)
                talkButton
                    .padding(.top, 28)
                    .padding(.bottom, 48)
            }
        }
    }

    private var talkButton: some View {
        Circle()
            .fill(Color(uiColor: accent).opacity(vm.state == .listening ? 0.85 : 0.22))
            .frame(width: 84, height: 84)
            .overlay(Image(systemName: "mic.fill").font(.title).foregroundStyle(.white))
            .overlay(Circle().stroke(Color(uiColor: accent), lineWidth: 2))
            .scaleEffect(vm.state == .listening ? 1.12 : 1.0)
            .animation(.spring(duration: 0.25), value: vm.state)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in vm.startTalking() }
                    .onEnded { _ in vm.stopTalking() }
            )
            .accessibilityLabel("Hold to talk to Jarvis")
    }
}
