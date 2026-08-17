import SwiftData
import SwiftUI

struct HomeView: View {
    let coordinator: RecordingCoordinator

    @Query(sort: \TrackSession.startedAt, order: .reverse) private var sessions: [TrackSession]

    var body: some View {
        List {
            if case .failed(let problem) = coordinator.phase {
                problemSection(problem)
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ready to record")
                        .font(.headline)
                    Button("Start Recording") {
                        Task { await coordinator.startRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("startRecording")
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Tracks stay on this iPhone until you export or delete them.")
            }

            Section {
                NavigationLink {
                    CameraClockView()
                } label: {
                    Label("Camera Clock", systemImage: "clock")
                }
                .accessibilityIdentifier("cameraClock")
            }

            if !sessions.isEmpty {
                Section("Recent") {
                    ForEach(sessions.prefix(20)) { session in
                        NavigationLink(value: session.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.name)
                                Text(
                                    Formatters.recentSessionSubtitle(
                                        startedAt: session.startedAt,
                                        endedAt: session.endedAt
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func problemSection(_ problem: RecordingProblem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.title).font(.headline)
                Text(problem.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if problem.suggestsSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
            }
            Button("Dismiss") { coordinator.dismissFailure() }
        }
    }
}
