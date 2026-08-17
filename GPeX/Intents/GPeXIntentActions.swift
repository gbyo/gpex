import Foundation

/// Everything App Intents are allowed to do to GPeX.
///
/// Two verbs, no state, no return values. An intent cannot reach the coordinator, the
/// store or the router through this — it can only ask the app to do something it
/// already does when a person taps a button, which is the point: the intent is a
/// second way in, never a second implementation.
protocol GPeXIntentActions: Sendable {
    /// Starts a recording, or does nothing if one is already under way.
    @MainActor func startRecording() async
    /// Navigates to the Camera Clock screen.
    @MainActor func openCameraClock()
}

/// The production implementation, wired to the objects `AppServices` already owns.
///
/// Every method here is a call into existing app behaviour plus a navigation nudge.
/// Nothing is duplicated: `startRecording()` is `RecordingCoordinator.startRecording()`
/// — which is what makes starting idempotent, since that method already refuses to
/// create a second recording while one is starting, recording or stopping.
@MainActor
final class AppIntentActions: GPeXIntentActions {
    private let coordinator: RecordingCoordinator
    private let router: AppRouter

    init(coordinator: RecordingCoordinator, router: AppRouter) {
        self.coordinator = coordinator
        self.router = router
    }

    func startRecording() async {
        // Pop to the root first. The root screen *is* the active recording screen
        // whenever a recording is running, so this is what "show the recording UI"
        // means — including in the already-recording case, where `startRecording()`
        // itself correctly does nothing.
        router.showActiveRecording()
        await coordinator.startRecording()
    }

    func openCameraClock() {
        router.showCameraClock()
    }
}
