import WidgetKit
import SwiftUI

/// The widget extension's entry point. Holds the Jarvis Live Activity (Dynamic Island +
/// Lock Screen). No home-screen widgets yet — the bundle exists so ActivityKit has a place
/// to render the activity.
@main
struct JarvisWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarvisLiveActivity()
    }
}
