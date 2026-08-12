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
        // again so Jarvis is never silently dead on reopen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.appDidBecomeActive() }
        }
    }
}
