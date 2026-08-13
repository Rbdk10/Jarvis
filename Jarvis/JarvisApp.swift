import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var vm = JarvisViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
        // iOS suspends the WebSocket in the background; reconnect the moment we're active
        // again so Jarvis is never silently dead on reopen. On the way out, keep playback
        // alive so he can still speak from the Dynamic Island while you're in another app.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     vm.appDidBecomeActive()
            case .background: vm.appDidEnterBackground()
            default:          break
            }
        }
    }
}
