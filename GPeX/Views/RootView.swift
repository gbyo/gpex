import SwiftUI

/// Where navigation lives.
///
/// The root content is the idle home screen or the active recording screen — never
/// both, because the recording state machine only permits one. Finishing a recording
/// pushes the completed session.
struct RootView: View {
    let coordinator: RecordingCoordinator
    let trackStore: TrackStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if coordinator.phase.isActive {
                    ActiveRecordingView(coordinator: coordinator)
                } else {
                    HomeView(coordinator: coordinator)
                }
            }
            .navigationTitle("GPeX")
            .navigationDestination(for: UUID.self) { sessionID in
                SessionDetailView(sessionID: sessionID, trackStore: trackStore)
            }
        }
        .onChange(of: coordinator.lastFinishedSessionID) { _, finished in
            guard let finished else { return }
            path = [finished]
            coordinator.clearLastFinishedSession()
        }
        .onOpenURL { url in
            // The Live Activity's only interaction. Popping to the root is enough: the
            // root already shows the active recording whenever one is running, so this
            // needs no routing machinery of its own.
            guard RecordingDeepLink.isActiveRecording(url) else { return }
            path.removeAll()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground is the one moment where recreating a missing
            // Live Activity is appropriate. Nothing about the recording depends on it.
            guard phase == .active else { return }
            coordinator.reconcileLiveActivity()
        }
    }
}
