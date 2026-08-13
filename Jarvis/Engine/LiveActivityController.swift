import ActivityKit
import Foundation

/// Drives Jarvis's Live Activity (Dynamic Island + Lock Screen). The app calls `sync` as
/// Jarvis's state changes: it starts the activity when he becomes active, updates it while he
/// works/speaks, and ends it a few seconds after he goes idle — so he's visibly present in the
/// island the moment you swipe out, and tidies himself away when he's done.
@MainActor
final class LiveActivityController {
    private var activity: Activity<JarvisActivityAttributes>?
    /// Guards the idle-linger teardown so a quick re-activation cancels a pending end.
    private var endTask: Task<Void, Never>?

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Reflect the current phase + line into the island.
    /// - active: Jarvis is doing something (listening/working/speaking) → show/keep the island.
    ///           false → he's idle; linger briefly on the last line, then end.
    func sync(phase: Phase, line: String, active: Bool) {
        guard enabled else { return }
        let content = ActivityContent(
            state: JarvisActivityAttributes.ContentState(phase: phase, line: line),
            staleDate: nil
        )

        if active {
            endTask?.cancel(); endTask = nil
            if let activity {
                Task { await activity.update(content) }
            } else {
                activity = try? Activity.request(
                    attributes: JarvisActivityAttributes(),
                    content: content
                )
            }
        } else {
            guard let activity else { return }
            // Update to the final line, then end after a short linger (unless re-activated).
            Task { await activity.update(content) }
            endTask?.cancel()
            endTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                await activity.end(content, dismissalPolicy: .immediate)
                self?.activity = nil
            }
        }
    }

    /// Force-end immediately (reset / teardown).
    func end() {
        endTask?.cancel(); endTask = nil
        guard let activity else { return }
        let a = activity; self.activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
