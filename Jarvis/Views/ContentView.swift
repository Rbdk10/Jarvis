import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var vm: JarvisViewModel

    // Blue-white throughout, per Antoonie. Only an error tints the orb red.
    private let blueWhite = UIColor(red: 0.55, green: 0.80, blue: 1.00, alpha: 1)
    private var accent: UIColor {
        if case .error = vm.state { return UIColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        return blueWhite
    }

    private var isThinking: Bool { vm.state == .thinking }

    @State private var showInput = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    @State private var showArtifacts = false
    @State private var expandedArtifact: JarvisArtifact?

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

            // Swipe down (toward the top) → text box at the top.
            VStack {
                if showInput {
                    textInputBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 6)

            // Swipe up (toward the bottom) → artifacts panel at the bottom.
            VStack {
                Spacer()
                if showArtifacts {
                    artifactsPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    guard abs(v.translation.height) > 50, abs(v.translation.width) < 120 else { return }
                    let down = v.translation.height > 0
                    // The orb screen is the "middle". Each swipe moves one step, always
                    // via the middle — never straight from text box to artifacts.
                    if showInput {
                        if !down { withAnimation { showInput = false }; inputFocused = false }  // up → back to middle
                    } else if showArtifacts {
                        if down { withAnimation { showArtifacts = false } }                     // down → back to middle
                    } else {
                        // at the middle: down → text box, up → artifacts
                        if down {
                            withAnimation { showInput = true }
                            inputFocused = true
                        } else {
                            withAnimation { showArtifacts = true }
                        }
                    }
                }
        )
        .sheet(item: $expandedArtifact) { art in
            ArtifactDetailView(artifact: art)
        }
    }

    /// Bottom panel: a chat-style list of artifact cards; tap one to expand it.
    private var artifactsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Artifacts").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { withAnimation { showArtifacts = false } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if vm.artifacts.isEmpty {
                Text("Nothing yet — anything I hand you will appear here.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.artifacts.reversed()) { art in
                            artifactCard(art).onTapGesture { expandedArtifact = art }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 16)
                }
                .frame(maxHeight: 320)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(uiColor: blueWhite).opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func artifactCard(_ art: JarvisArtifact) -> some View {
        HStack(spacing: 12) {
            Image(systemName: artifactIcon(art.kind))
                .font(.system(size: 18))
                .foregroundStyle(Color(uiColor: blueWhite))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(art.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Text(art.kind.capitalized).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private func artifactIcon(_ kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "html":  return "doc.richtext"
        default:       return "doc.text"
        }
    }

    /// Swipe-down text entry — type/paste a message; sent to Jarvis like a voice command.
    private var textInputBar: some View {
        HStack(spacing: 10) {
            TextField("Type or paste for Jarvis…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .foregroundStyle(.white)
                .tint(Color(uiColor: blueWhite))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(uiColor: blueWhite))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                withAnimation { showInput = false }
                inputFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(uiColor: blueWhite).opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 12)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        withAnimation { showInput = false }
        inputFocused = false
        vm.sendTyped(text)
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

/// Full-screen view of a tapped artifact — renders text, HTML, or a base64 image.
struct ArtifactDetailView: View {
    let artifact: JarvisArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch artifact.kind {
                case "image":
                    if let img = decodeImage(artifact.data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: img).resizable().scaledToFit()
                        }
                    } else {
                        Text("Couldn't load this image.").foregroundStyle(.secondary)
                    }
                case "html":
                    HTMLView(html: artifact.data)
                default:
                    ScrollView {
                        Text(artifact.data)
                            .font(.system(size: 15, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(artifact.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func decodeImage(_ b64: String) -> UIImage? {
        var s = b64
        if s.hasPrefix("data:"), let comma = s.range(of: ",") { s = String(s[comma.upperBound...]) }
        guard let data = Data(base64Encoded: s) else { return nil }
        return UIImage(data: data)
    }
}

struct HTMLView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
