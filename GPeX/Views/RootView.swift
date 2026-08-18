import SwiftUI

/// Where navigation lives.
///
/// The root content is the idle home screen or the active recording screen — never
/// both, because the recording state machine only permits one. Everything pushed on
/// top of it comes from `AppRouter`, so an App Intent can reach the same destinations
/// a tap does without this view growing a second way to navigate.
struct RootView: View {
    let coordinator: RecordingCoordinator
    let trackStore: TrackStore
    @Bindable var router: AppRouter

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if coordinator.phase.isActive {
                    ActiveRecordingView(coordinator: coordinator)
                } else {
                    HomeView(coordinator: coordinator)
                }
            }
            .navigationTitle("GPeX")
            .navigationDestination(for: AppRouter.Destination.self) { destination in
                switch destination {
                case .cameraClock:
                    CameraClockView()
                case .session(let sessionID):
                    SessionDetailView(sessionID: sessionID, trackStore: trackStore)
                }
            }
        }
        .sensoryFeedback(trigger: coordinator.phase.isActive) { wasActive, isActive in
            // Confirmation that carries when the phone is already back in a pocket. The
            // trigger is the active/idle Bool, not `phase`, so the many moving ↔
            // stationary ↔ unavailable transitions during a recording stay silent.
            switch (wasActive, isActive) {
            case (false, true):
                return .start
            case (true, false):
                // A start that never got off the ground ends in `.failed`. That is a
                // failure, not a finished recording, so it gets no stop haptic.
                if case .failed = coordinator.phase { return nil }
                return .stop
            default:
                return nil
            }
        }
        .onChange(of: coordinator.lastFinishedSessionID) { _, finished in
            guard let finished else { return }
            router.showSession(finished)
            coordinator.clearLastFinishedSession()
        }
        .onOpenURL { url in
            // The Live Activity's only interaction. Popping to the root is enough: the
            // root already shows the active recording whenever one is running, so this
            // needs no routing machinery of its own.
            guard RecordingDeepLink.isActiveRecording(url) else { return }
            router.showActiveRecording()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground is the one moment where recreating a missing
            // Live Activity is appropriate. Nothing about the recording depends on it.
            guard phase == .active else { return }
            coordinator.reconcileLiveActivity()
        }
    }
}
