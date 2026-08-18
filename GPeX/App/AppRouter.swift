import Foundation
import Observation

/// Where the app is, as a value something other than a view can set.
///
/// This exists because App Intents have to be able to say "show the recording" or
/// "show the Camera Clock" from outside the view hierarchy. It is deliberately not a
/// routing framework: one array, three verbs, and the same destinations the UI already
/// had. `RootView` still decides *what* the root screen is from
/// `RecordingCoordinator.phase` — the router only drives what is pushed on top of it.
@Observable
final class AppRouter {
    /// The screens reachable from the root. Both already existed as navigation links;
    /// naming them is what lets an intent reach them.
    enum Destination: Hashable {
        case cameraClock
        case session(UUID)
    }

    /// Bound directly to the `NavigationStack`, so the user's own back-swipes keep
    /// working without the router having to hear about them.
    var path: [Destination] = []

    /// Pops back to the root, which is the active recording screen whenever a
    /// recording is running.
    func showActiveRecording() {
        guard !path.isEmpty else { return }
        path.removeAll()
    }

    func showCameraClock() {
        guard path != [.cameraClock] else { return }
        path = [.cameraClock]
    }

    /// Shows a finished session. Used when a recording stops, and by the detail links.
    func showSession(_ sessionID: UUID) {
        guard path != [.session(sessionID)] else { return }
        path = [.session(sessionID)]
    }
}
