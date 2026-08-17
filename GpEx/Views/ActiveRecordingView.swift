import SwiftUI

/// The active recording screen: unmistakable, but restrained.
///
/// Every status is spelled out in words as well as an icon, so nothing depends on
/// colour alone.
struct ActiveRecordingView: View {
    let coordinator: RecordingCoordinator

    @State private var timerAnchor = Date()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(coordinator.phase.headline)
                        .font(.headline)
                        .accessibilityIdentifier("recordingHeadline")

                    if let startedAt = coordinator.startedAt {
                        TimelineView(.periodic(from: timerAnchor, by: 1)) { context in
                            let elapsed = context.date.timeIntervalSince(startedAt)
                            Text(Formatters.elapsedClock(elapsed))
                                .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                                .monospacedDigit()
                                .accessibilityLabel("Recording time \(Formatters.spokenDuration(elapsed))")
                        }
                    }

                    if let detail = coordinator.phase.activityDetail,
                       coordinator.phase.activityTitle == nil {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let activity = coordinator.phase.activityTitle {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity)
                            if let detail = coordinator.phase.activityDetail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("activityStatus")
                }

                if let sample = coordinator.latestSample {
                    LabeledContent("Accuracy") {
                        Text("\(Formatters.accuracy(sample.horizontalAccuracy)) · \(sample.quality.label)")
                    }
                }

                LabeledContent("Locations") {
                    Text("\(coordinator.recordedPointCount)")
                }
                .accessibilityLabel("\(coordinator.recordedPointCount) locations recorded")
            }

            if coordinator.isPreciseLocationDenied {
                reducedAccuracySection
            }

            if coordinator.isBackgroundActivityLimited {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background recording is limited").font(.headline)
                        Text("iOS has paused location updates for PhotoTrack. Keeping PhotoTrack open will record reliably.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Stop Recording", role: .destructive) {
                    Task { await coordinator.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(coordinator.phase == .stopping)
                .accessibilityIdentifier("stopRecording")
            }
        }
    }

    @ViewBuilder
    private var reducedAccuracySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reduced Accuracy").font(.headline)
                Text("Precise Location is off. Photo positioning may be inaccurate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
            }
        }
    }
}
