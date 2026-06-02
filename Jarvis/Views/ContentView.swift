import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: JarvisViewModel

    // Blue-white throughout, per Antoonie. Only an error tints the orb red.
    private let blueWhite = UIColor(red: 0.55, green: 0.80, blue: 1.00, alpha: 1)
    private var accent: UIColor {
        if case .error = vm.state { return UIColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        return blueWhite
    }

    private var isThinking: Bool { vm.state == .thinking }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(white: 0.06), .black],
                           center: .center, startRadius: 5, endRadius: 500)
                .ignoresSafeArea()

            OrbView(level: vm.level, accent: accent)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Tap anywhere on the core/background to start listening (no greeting).
            // Sits beneath the bottom controls, so the mic/stop button still get their taps.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { vm.tapToListen() }

            // Live activity log — what Jarvis is doing while thinking. Sits above the
            // orb and quietly disappears once he starts speaking or goes idle.
            VStack {
                if isThinking {
                    activityLine
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.25), value: isThinking)

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
                Group {
                    if vm.state == .speaking {
                        stopButton
                    } else {
                        listenToggle
                    }
                }
                .padding(.top, 28)
                .padding(.bottom, 48)
            }
        }
    }

    /// Shown only while Jarvis is speaking — tap to interrupt and start talking.
    private var stopButton: some View {
        Circle()
            .fill(Color(uiColor: blueWhite).opacity(0.18))
            .frame(width: 84, height: 84)
            .overlay(Image(systemName: "stop.fill").font(.title).foregroundStyle(.white))
            .overlay(Circle().stroke(Color(uiColor: blueWhite), lineWidth: 2))
            .onTapGesture { vm.interrupt() }
            .accessibilityLabel("Stop Jarvis and talk")
    }

    private var activityLine: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(Color(uiColor: blueWhite))
            Text(vm.statusText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(uiColor: blueWhite).opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().stroke(Color(uiColor: blueWhite).opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 24)
    }

    /// Hands-free toggle: tap to pause/resume automatic listening. Pulses while listening.
    private var listenToggle: some View {
        let listening = vm.state == .listening
        let icon = vm.handsFree ? "mic.fill" : "mic.slash.fill"
        return Circle()
            .fill(Color(uiColor: accent).opacity(listening ? 0.85 : (vm.handsFree ? 0.22 : 0.10)))
            .frame(width: 84, height: 84)
            .overlay(Image(systemName: icon).font(.title).foregroundStyle(.white))
            .overlay(Circle().stroke(Color(uiColor: accent), lineWidth: 2))
            .scaleEffect(listening ? 1.12 : 1.0)
            .animation(.spring(duration: 0.25), value: vm.state)
            .onTapGesture { vm.toggleHandsFree() }
            .accessibilityLabel(vm.handsFree ? "Listening hands-free. Tap to pause." : "Listening paused. Tap to resume.")
    }
}
