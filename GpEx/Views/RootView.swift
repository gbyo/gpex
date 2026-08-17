import SwiftUI

/// Where navigation lives.
///
/// The root content is the idle home screen or the active recording screen — never
/// both, because the recording state machine only permits one. Finishing a recording
/// pushes the completed session.
struct RootView: View {
    let coordinator: RecordingCoordinator
    let trackStore: TrackStore

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
            .navigationTitle("PhotoTrack")
            .navigationDestination(for: UUID.self) { sessionID in
                SessionDetailView(sessionID: sessionID, trackStore: trackStore)
            }
        }
        .onChange(of: coordinator.lastFinishedSessionID) { _, finished in
            guard let finished else { return }
            path = [finished]
            coordinator.clearLastFinishedSession()
        }
    }
}
