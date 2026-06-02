import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var vm = JarvisViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
