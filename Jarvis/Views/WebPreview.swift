import SwiftUI
import WebKit
import UIKit

// MARK: - Web model

/// Owns a WKWebView and publishes its navigation state so the SwiftUI controls (loading
/// spinner, back/forward, errors, desktop/mobile mode) can drive and reflect it.
///
/// Not @MainActor: WKNavigationDelegate callbacks already arrive on the main thread, and
/// keeping it plain avoids actor-isolation friction on the delegate conformance.
final class PreviewWebModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorText: String?
    /// Request the desktop layout instead of the phone one. Re-loads on change so the new
    /// content mode (applied in decidePolicyFor) takes effect.
    @Published var desktop = false { didSet { if oldValue != desktop { reload() } } }

    let webView = WKWebView()
    private var lastURL: URL?

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // Off, so a horizontal swipe doesn't get eaten by web back/forward — we use it to
        // close the panel instead (web history is still reachable via the nav-bar buttons).
        webView.allowsBackForwardNavigationGestures = false
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = rc
    }

    func load(_ raw: String) {
        guard let url = Self.url(from: raw) else {
            errorText = "That doesn't look like a web address."
            return
        }
        lastURL = url
        errorText = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        errorText = nil
        if webView.url != nil { webView.reload() }
        else if let u = lastURL { webView.load(URLRequest(url: u)) }
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func stop() { webView.stopLoading(); isLoading = false }

    @objc private func pullRefresh() { reload() }

    static func url(from raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return URL(string: t.contains("://") ? t : "https://\(t)")
    }

    // MARK: WKNavigationDelegate (main-thread callbacks)

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        isLoading = true; errorText = nil
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { settle(w) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { settle(w, e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { settle(w, e) }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 preferences p: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        p.preferredContentMode = desktop ? .desktop : .mobile
        decisionHandler(.allow, p)
    }

    private func settle(_ w: WKWebView, _ error: Error? = nil) {
        isLoading = false
        canGoBack = w.canGoBack
        canGoForward = w.canGoForward
        w.scrollView.refreshControl?.endRefreshing()
        if let error, (error as NSError).code != NSURLErrorCancelled {
            errorText = (error as NSError).localizedDescription
        }
    }
}

// MARK: - WKWebView host

struct PreviewWebView: UIViewRepresentable {
    let model: PreviewWebModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - The swipe-left preview panel

/// A full-height in-app browser: address bar (remembered), reload/stop, back/forward,
/// a desktop-layout toggle, pull-to-refresh, saved-URL chips, and clear loading/error
/// states. Point it at whatever Jarvis serves (e.g. a build over an ngrok tunnel).
struct WebPreviewPanel: View {
    @Binding var isPresented: Bool
    private let accent = Color(red: 0.55, green: 0.80, blue: 1.0)   // blue-white, matches the app

    @StateObject private var web = PreviewWebModel()
    // A small browser for public sites. Empty by default — type an address, or let the
    // agent push one ("show me the page of …", which sets this via ContentView).
    @AppStorage("jarvisPreviewURL") private var committedURL = ""
    @AppStorage("jarvisPreviewSlots") private var slotsRaw = ""     // saved URLs, newline-joined
    @State private var address = ""

    // The old Tailscale dev-server URL that used to be the default — clear it on existing
    // installs so the projector starts clean for public sites.
    private let retiredDefault = "http://100.115.244.72:5173"

    private var slots: [String] { slotsRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            toolBar
            ZStack {
                Color(white: 0.05)
                PreviewWebView(model: web)
                if committedURL.isEmpty && web.errorText == nil { placeholder }
                if let err = web.errorText { errorView(err) }
                if web.isLoading {
                    ProgressView().tint(accent).scaleEffect(1.2)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .overlay(alignment: .leading) {
                // The web view eats normal drags, so grab a thin strip at the left edge for a
                // swipe-back-to-close (iOS-style). Swipe right from the edge → close the panel.
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onEnded { v in
                                if v.translation.width > 45,
                                   abs(v.translation.width) > abs(v.translation.height) {
                                    withAnimation { isPresented = false }
                                }
                            }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if committedURL == retiredDefault { committedURL = "" }   // migrate off the old dev URL
            address = committedURL
            if web.webView.url == nil, !committedURL.isEmpty { web.load(committedURL) }
        }
        // The agent (or a saved chip) can change the URL while we're open → load it.
        .onChange(of: committedURL) { _, new in
            guard new != retiredDefault, !new.isEmpty else { return }
            address = new
            web.load(new)
        }
    }

    // Row 1 — close · back · forward · address · reload/stop
    private var navBar: some View {
        HStack(spacing: 8) {
            icon("chevron.right") { withAnimation { isPresented = false } }
            icon("chevron.backward", on: web.canGoBack) { web.goBack() }
            icon("chevron.forward", on: web.canGoForward) { web.goForward() }
            TextField("https://… (public site)", text: $address)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .tint(accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(go)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            icon(web.isLoading ? "xmark" : "arrow.clockwise") {
                if web.isLoading { web.stop() } else { web.reload() }
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
    }

    // Row 2 — desktop toggle · bookmark · saved-URL chips
    private var toolBar: some View {
        HStack(spacing: 8) {
            Button { web.desktop.toggle() } label: {
                Image(systemName: web.desktop ? "desktopcomputer" : "iphone")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(web.desktop ? accent : .white.opacity(0.5))
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(web.desktop ? accent.opacity(0.18) : .white.opacity(0.06)))
            }
            icon("bookmark") { saveSlot() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(slots, id: \.self) { chip($0) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ s: String) -> some View {
        HStack(spacing: 5) {
            Text(host(s)).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Button { removeSlot(s) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
        .foregroundStyle(.white.opacity(0.85))
        .contentShape(Capsule())
        .onTapGesture { address = s; committedURL = s; web.load(s) }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.white.opacity(0.22))
            Text("Type a site address above and tap Go,\nor ask Jarvis to show you a page.")
                .font(.footnote).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30)).foregroundStyle(.orange.opacity(0.85))
            Text("Couldn't load that page").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(msg).font(.footnote).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Button { web.reload() } label: {
                Text("Retry").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(accent.opacity(0.2)))
                    .overlay(Capsule().stroke(accent, lineWidth: 1))
                    .foregroundStyle(accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
    }

    private func icon(_ name: String, on enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? accent : .white.opacity(0.22))
                .frame(width: 30, height: 30)
        }
        .disabled(!enabled)
    }

    // MARK: actions

    private func go() {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        committedURL = t
        web.load(t)
    }

    private func saveSlot() {
        let t = committedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = slots.filter { $0 != t }
        list.insert(t, at: 0)
        slotsRaw = list.prefix(4).joined(separator: "\n")   // keep the 4 most recent
    }

    private func removeSlot(_ s: String) {
        slotsRaw = slots.filter { $0 != s }.joined(separator: "\n")
    }

    private func host(_ s: String) -> String { PreviewWebModel.url(from: s)?.host ?? s }
}
