import SwiftData
import SwiftUI

/// Sets a session's camera clock correction.
///
/// The sign is never left implicit: the screen states the direction in words and shows
/// the signed adjustment that will be applied to the exported timestamps.
struct ClockCorrectionView: View {
    let sessionID: UUID
    let trackStore: TrackStore

    @State private var correction: ClockCorrection

    init(sessionID: UUID, trackStore: TrackStore, offsetSeconds: Double) {
        self.sessionID = sessionID
        self.trackStore = trackStore
        _correction = State(initialValue: ClockCorrection(offsetSeconds: offsetSeconds))
    }

    var body: some View {
        List {
            Section {
                Picker("Camera clock was", selection: $correction.direction) {
                    ForEach(ClockCorrection.Direction.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("correctionDirection")
            } footer: {
                Text("Fast means the camera clock read later than this iPhone. Slow means it read earlier.")
            }

            Section {
                Stepper("Hours: \(correction.hours)", value: $correction.hours, in: 0...23)
                    .accessibilityIdentifier("correctionHours")
                Stepper("Minutes: \(correction.minutes)", value: $correction.minutes, in: 0...59)
                    .accessibilityIdentifier("correctionMinutes")
                Stepper("Seconds: \(correction.seconds)", value: $correction.seconds, in: 0...59)
                    .accessibilityIdentifier("correctionSeconds")
            }

            Section {
                LabeledContent("Correction") {
                    Text(correction.summary)
                        .accessibilityIdentifier("correctionSummary")
                }
                LabeledContent("Export adjustment") {
                    Text(correction.signedAdjustment)
                        .monospacedDigit()
                        .accessibilityIdentifier("signedExportAdjustment")
                        .accessibilityLabel(correction.spokenAdjustment)
                        .accessibilityValue(correction.signedAdjustment)
                }
                .accessibilityIdentifier("exportAdjustment")
            } footer: {
                Text("Recorded positions keep their real timestamps. Only the exported GPX file is shifted.")
            }

            if !correction.isNone {
                Section {
                    Button("Clear Correction") { correction = .none }
                }
            }
        }
        .navigationTitle("Camera Clock Correction")
        .navigationBarTitleDisplayMode(.inline)
        // Saved as the user adjusts, so there is no Save button to forget.
        .onChange(of: correction) { _, updated in
            Task { try? await trackStore.setCameraClockOffset(sessionID: sessionID, seconds: updated.offsetSeconds) }
        }
    }
}

#if DEBUG
private struct ClockCorrectionPreview: View {
    let offsetSeconds: Double
    @State private var world = PreviewWorld()

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if let id = world.firstSessionID {
                    ClockCorrectionView(
                        sessionID: id,
                        trackStore: world.store,
                        offsetSeconds: offsetSeconds
                    )
                }
            }
        }
        .modelContainer(world.container)
    }
}

#Preview("No correction") {
    ClockCorrectionPreview(offsetSeconds: 0)
}

#Preview("Camera 5 s slow") {
    ClockCorrectionPreview(offsetSeconds: -5)
}

#Preview("Camera 1 h 2 m fast") {
    ClockCorrectionPreview(offsetSeconds: 3_720)
}
#endif
