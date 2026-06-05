import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var vm: JarvisViewModel

    // UI chrome stays cool blue-white. Only an error tints it red.
    private let blueWhite = UIColor(red: 0.55, green: 0.80, blue: 1.00, alpha: 1)
    private var accent: UIColor {
        if case .error = vm.state { return UIColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        return blueWhite
    }

    // The energy orb: amber by default (the J.A.R.V.I.S. look), blue while *you* talk.
    private let orbAmber = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1)
    private let orbBlue  = UIColor(red: 0.30, green: 0.66, blue: 1.0, alpha: 1)
    private var orbAccent: UIColor {
        if case .error = vm.state { return UIColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        return vm.state == .listening ? orbBlue : orbAmber
    }

    private var isThinking: Bool { vm.state == .thinking }

    @State private var showInput = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    @State private var showArtifacts = false
    @State private var expandedArtifact: JarvisArtifact?

    @State private var showLog = false

    // Swipe-left web preview (right drawer) — eyeball what Jarvis serves, e.g. a build over
    // an ngrok tunnel. Self-contained in WebPreviewPanel; URL + slots persist there.
    @State private var showPreview = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(white: 0.06), .black],
                           center: .center, startRadius: 5, endRadius: 500)
                .ignoresSafeArea()

            OrbView(level: vm.level, accent: orbAccent)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Faint HUD: a couple of concentric rings + corner ticks around the orb.
            hudOverlay
                .allowsHitTesting(false)

            // Tap anywhere on the core/background to start listening (no greeting).
            // Sits beneath the bottom controls, so the mic/stop button still get their taps.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { vm.tapToListen() }

            // Always-available "stop listening" toggle (top-right). Mute me entirely —
            // wake word and mic off — so a movie or background telly won't trigger me.
            if !showInput {
                VStack {
                    HStack {
                        if vm.state == .speaking {
                            stopSignButton.padding(.leading, 16).padding(.top, 10)
                        }
                        Spacer()
                        muteButton.padding(.trailing, 16).padding(.top, 10)
                    }
                    Spacer()
                }
            }

            // Two-button routing override at the very top: lock to Chatbot or Agent.
            if !showInput {
                VStack {
                    modeToggle.padding(.top, 10)
                    Spacer()
                }
            }

            // Live activity log — what Jarvis is doing while thinking. Sits above the
            // orb and quietly disappears once he starts speaking or goes idle.
            VStack {
                if isThinking {
                    activityLine
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 56)
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
                    } else if vm.state == .listening {
                        submitButton
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

            // Swipe right → activity log (left drawer): step-by-step, timestamped.
            HStack(spacing: 0) {
                if showLog {
                    activityLogPanel
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }

            // Swipe left → web preview (right drawer): eyeball a build from your phone.
            if showPreview {
                WebPreviewPanel(isPresented: $showPreview)
                    .transition(.move(edge: .trailing))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    if abs(dx) > abs(dy) {
                        // Horizontal. Right → activity log (left drawer); left → web preview
                        // (right drawer). Swiping the opposite way closes whichever is open.
                        guard abs(dx) > 50 else { return }
                        if dx > 0 {
                            if showPreview { withAnimation { showPreview = false } }
                            else {
                                withAnimation { showLog = true; showInput = false; showArtifacts = false }
                                inputFocused = false
                            }
                        } else {
                            if showLog { withAnimation { showLog = false } }
                            else {
                                withAnimation { showPreview = true; showInput = false; showArtifacts = false }
                                inputFocused = false
                            }
                        }
                        return
                    }
                    // Vertical: the orb screen is the "middle"; one step at a time.
                    guard abs(dy) > 50 else { return }
                    if showLog { withAnimation { showLog = false }; return }
                    let down = dy > 0
                    if showInput {
                        if !down { withAnimation { showInput = false }; inputFocused = false }  // up → middle
                    } else if showArtifacts {
                        if down { withAnimation { showArtifacts = false } }                     // down → middle
                    } else {
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

    /// Swipe-right drawer: a timestamped, step-by-step trace of what Jarvis is doing,
    /// with the gap between each step — to see where the response time goes.
    private var activityLogPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation { showLog = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text("Activity").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)

            if vm.activityLog.isEmpty {
                Spacer()
                Text("No activity yet.\nTalk to me and the steps\nappear here, timed.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(vm.activityLog.enumerated()), id: \.element.id) { i, entry in
                                logRow(entry, prev: i > 0 ? vm.activityLog[i - 1] : nil).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 20)
                    }
                    .onChange(of: vm.activityLog.count) {
                        if let last = vm.activityLog.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(uiColor: blueWhite).opacity(0.25)).frame(width: 1)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private func logRow(_ e: ActivityEntry, prev: ActivityEntry?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(clockString(e.time))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                if let prev {
                    Text(deltaString(prev.time, e.time))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(uiColor: blueWhite).opacity(0.85))
                }
            }
            .frame(width: 62, alignment: .trailing)
            Text(e.text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func clockString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
    private func deltaString(_ a: Date, _ b: Date) -> String {
        String(format: "+%.1fs", b.timeIntervalSince(a))
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

    /// Faint heads-up display around the orb: two concentric rings + corner ticks.
    private var hudOverlay: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .stroke(Color(uiColor: orbAccent).opacity(0.12), lineWidth: 1)
                    .frame(width: 300, height: 300).position(c)
                Circle()
                    .stroke(Color(uiColor: orbAccent).opacity(0.16),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 9]))
                    .frame(width: 344, height: 344).position(c)
                ForEach(0..<4, id: \.self) { i in cornerTick(i, in: geo.size) }
            }
        }
    }

    private func cornerTick(_ idx: Int, in size: CGSize) -> some View {
        let inset: CGFloat = 20, len: CGFloat = 16
        let specs: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: inset, y: inset), 1, 1),
            (CGPoint(x: size.width - inset, y: inset), -1, 1),
            (CGPoint(x: inset, y: size.height - inset), 1, -1),
            (CGPoint(x: size.width - inset, y: size.height - inset), -1, -1)
        ]
        let (p, sx, sy) = specs[idx]
        return Path { path in
            path.move(to: CGPoint(x: p.x + sx * len, y: p.y))
            path.addLine(to: p)
            path.addLine(to: CGPoint(x: p.x, y: p.y + sy * len))
        }
        .stroke(Color(uiColor: orbAccent).opacity(0.22), lineWidth: 1.5)
    }

    /// Two-button routing override. Lock the conversation to the Chatbot (instant, on-device)
    /// or the Agent (the mini). Tap the lit one again to return to Auto (smart routing).
    private var modeToggle: some View {
        HStack(spacing: 4) {
            modeButton("Chatbot", mode: .chatbot, tint: orbBlue)
            modeButton("Agent", mode: .agent, tint: orbAmber)
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func modeButton(_ title: String, mode: JarvisViewModel.RouteMode, tint: UIColor) -> some View {
        let active = vm.routeMode == mode
        return Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? .white : .white.opacity(0.55))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(active ? Color(uiColor: tint).opacity(0.9) : Color.clear))
            .contentShape(Capsule())
            .onTapGesture { vm.setMode(active ? .auto : mode) }
            .accessibilityLabel("\(title)\(active ? ", selected. Tap to return to auto" : "")")
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

    /// Always-on listening toggle. Off = fully deaf (no wake word, no mic) so ambient
    /// audio (a film, the telly) can't trigger Jarvis. Tap to resume.
    /// Top-left stop sign — a clear, deliberate way to stop Jarvis talking, away from
    /// the orb. Shown only while speaking.
    private var stopSignButton: some View {
        Button { vm.interrupt() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.85, green: 0.22, blue: 0.20).opacity(0.85)))
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
        }
        .accessibilityLabel("Stop Jarvis talking")
    }

    private var muteButton: some View {
        Button { vm.toggleHandsFree() } label: {
            Image(systemName: vm.handsFree ? "ear.fill" : "ear.slash.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(vm.handsFree ? Color(uiColor: blueWhite) : .white.opacity(0.45))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.08)))
                .overlay(Circle().stroke((vm.handsFree ? Color(uiColor: blueWhite) : .white).opacity(0.3), lineWidth: 1))
        }
        .accessibilityLabel(vm.handsFree ? "Listening is on. Tap to stop listening." : "Listening is off. Tap to resume.")
    }

    /// Shown while listening (blue): tap to submit what you've said and send it.
    private var submitButton: some View {
        Circle()
            .fill(Color(uiColor: blueWhite).opacity(0.85))
            .frame(width: 84, height: 84)
            .overlay(Image(systemName: "arrow.up").font(.system(size: 30, weight: .bold)).foregroundStyle(.white))
            .overlay(Circle().stroke(Color(uiColor: blueWhite), lineWidth: 2))
            .scaleEffect(1.08)
            .onTapGesture { vm.submitListening() }
            .accessibilityLabel("Done — send what I said")
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

/// Live web view for the swipe-left preview. Loads a URL (defaulting to https:// when no
/// scheme is given) and reloads when the URL changes or the refresh button bumps the token.
