import SwiftUI

/// The active recording screen: unmistakable, but restrained.
///
/// This is the one screen a photographer looks at mid-event, usually for under a
/// second, so it is laid out as a single glance rather than a list of rows: status,
/// elapsed time, and the two numbers that say whether the recording is any good.
///
/// Every status is spelled out in words as well as an icon, so nothing depends on
/// colour alone.
struct ActiveRecordingView: View {
    let coordinator: RecordingCoordinator

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 64

    var body: some View {
        // `minHeight` plus centre alignment is what makes this a hero rather than a
        // list: with nothing but status, timer and two figures the content sits in the
        // middle of the screen, and when a notice or an accessibility text size makes
        // it taller than the screen it grows downwards and scrolls instead of clipping.
        GeometryReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 24) {
                        statusPill
                        elapsedTime
                        statistics
                        cadence
                        notices
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            // The content usually fits; bouncing an unscrollable screen would suggest
            // there is more below it than there is.
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) { stopBar }
    }

    // MARK: - Status

    private var statusPill: some View {
        Label {
            Text(coordinator.phase.statusTitle)
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: coordinator.phase.symbolName)
                .symbolEffect(.pulse, isActive: coordinator.phase.symbolPulses)
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(coordinator.phase.tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        // The headline and the activity line below are one thought, not two.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recordingHeadline")
        .animation(.snappy, value: coordinator.phase)
    }

    // MARK: - Elapsed time

    @ViewBuilder
    private var elapsedTime: some View {
        VStack(spacing: 4) {
            Text("ELAPSED")
                .font(.caption2.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            if let startedAt = coordinator.startedAt {
                // System-driven: the text updates itself without invalidating this
                // view every second, and it is the same construct the Live Activity
                // uses, so the Lock Screen and the app cannot drift apart.
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: timerSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("elapsedTime")
            } else {
                Text("--:--")
                    .font(.system(size: timerSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let detail = coordinator.phase.activityDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: coordinator.phase)
    }

    // MARK: - Numbers

    private var statistics: some View {
        HStack(spacing: 12) {
            StatCard(
                caption: "Locations",
                symbolName: "mappin.and.ellipse",
                tint: .secondary
            ) {
                Text("\(coordinator.recordedPointCount)")
                    .contentTransition(.numericText())
                    .animation(.snappy, value: coordinator.recordedPointCount)
            }
            .accessibilityLabel("\(coordinator.recordedPointCount) locations recorded")
            .accessibilityIdentifier("locationCount")

            if let sample = coordinator.latestSample {
                StatCard(
                    caption: "Accuracy",
                    symbolName: sample.quality.symbolName,
                    tint: sample.quality.tint
                ) {
                    Text(Formatters.accuracy(sample.horizontalAccuracy))
                }
                .accessibilityLabel(
                    "Accuracy \(Formatters.accuracy(sample.horizontalAccuracy)), \(sample.quality.label)"
                )
                .accessibilityIdentifier("accuracy")
            } else {
                StatCard(
                    caption: "Accuracy",
                    symbolName: "location.magnifyingglass",
                    tint: .secondary
                ) {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Accuracy not yet available")
                .accessibilityIdentifier("accuracy")
            }
        }
    }

    // MARK: - Cadence

    /// The interval this recording is running at.
    ///
    /// Stated rather than adjustable: a session half recorded at one cadence should
    /// finish at that cadence, and a control here would be one more thing to fumble
    /// mid-event. It is a caption, not a card, because it does not change.
    private var cadence: some View {
        Text(coordinator.saveInterval.cadenceDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("saveIntervalCadence")
    }

    // MARK: - Things the photographer can act on

    @ViewBuilder
    private var notices: some View {
        if coordinator.isPreciseLocationDenied {
            NoticeCard(
                title: "Reduced Accuracy",
                detail: "Precise Location is off. Photo positioning may be inaccurate.",
                symbolName: "location.slash.fill",
                tint: .orange,
                showsSettingsLink: true
            )
            .accessibilityIdentifier("reducedAccuracyNotice")
        }

        if coordinator.isBackgroundActivityLimited {
            NoticeCard(
                title: "Background recording is limited",
                detail: "iOS has paused location updates for GPeX. Keeping GPeX open will record reliably.",
                symbolName: "moon.zzz.fill",
                tint: .orange
            )
            .accessibilityIdentifier("backgroundLimitedNotice")
        }
    }

    // MARK: - Stop

    private var stopBar: some View {
        Button(role: .destructive) {
            Task { await coordinator.stopRecording() }
        } label: {
            Label("Stop Recording", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(coordinator.phase == .stopping)
        .accessibilityIdentifier("stopRecording")
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

#if DEBUG
#Preview("Tracking") {
    RecordingPreviewHost(stage: .tracking) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

#Preview("Stationary") {
    RecordingPreviewHost(stage: .stationary) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

#Preview("Acquiring") {
    RecordingPreviewHost(stage: .acquiring) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

#Preview("Location unavailable") {
    RecordingPreviewHost(stage: .unavailable) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

#Preview("Reduced accuracy") {
    RecordingPreviewHost(stage: .reducedAccuracy) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

#Preview("Background limited") {
    RecordingPreviewHost(stage: .backgroundLimited) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
}

// The screen a photographer reads at arm's length in bright sun, at the largest
// accessibility text size. If the timer truncates here, it truncates in the field.
#Preview("Tracking · AX5") {
    RecordingPreviewHost(stage: .tracking) { coordinator in
        PreviewNavigation(title: "GPeX") {
            ActiveRecordingView(coordinator: coordinator)
        }
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
