import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island presentations of an active GPeX recording.
///
/// A read-only projection. No Core Location, no SwiftData, no App Intents, no state of
/// its own. It renders whatever `RecordingActivityAttributes.ContentState` it is given,
/// and it renders the elapsed time itself from the static `startedAt` so the app never
/// has to wake up to advance a clock.
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(startedAt: context.attributes.startedAt, state: context.state)
                // Tapping opens the recording screen. There is deliberately no Stop
                // button here: ending a multi-hour track from a pocket would be costly.
                .widgetURL(RecordingDeepLink.activeRecording)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingIndicator(title: RecordingText.compactTitle)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(startedAt: context.attributes.startedAt)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedDetail(state: context.state)
                }
            } compactLeading: {
                RecordingIndicator(title: nil)
            } compactTrailing: {
                ElapsedTime(startedAt: context.attributes.startedAt)
                    .font(.caption.weight(.semibold))
            } minimal: {
                RecordingIndicator(title: nil)
            }
            .widgetURL(RecordingDeepLink.activeRecording)
            .keylineTint(.red)
        }
    }
}

// MARK: - Lock Screen

/// ```
/// ● GPeX Recording                    1:42:18
/// Stationary
/// Accuracy ±7 m                        38 locations
/// ```
///
/// No custom background, no gradient, no oversized type. It sits among the system's own
/// Lock Screen content and should look like it belongs there.
private struct LockScreenView: View {
    let startedAt: Date
    let state: RecordingActivityAttributes.ContentState

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RecordingIndicator(title: RecordingText.lockScreenTitle)
                Spacer(minLength: 8)
                ElapsedTime(startedAt: startedAt)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
            }

            StatusLine(status: state.status, showsDetail: !isLuminanceReduced)

            measurements

            if state.reducedAccuracy {
                ReducedAccuracyNote()
            }
        }
        // 14 pt on all sides is Apple's standard Lock Screen layout margin for a Live
        // Activity. The system's own inset sits outside this, which is why the title
        // still needs `minimumScaleFactor` to survive the narrowest widths.
        .padding(14)
    }

    /// Accuracy on the left, count on the right — or just the count when there is no
    /// current fix to describe.
    @ViewBuilder
    private var measurements: some View {
        if let accuracy = state.accuracyText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Accuracy \(accuracy)")
                    .accessibilityLabel(state.spokenAccuracy ?? accuracy)
                Spacer(minLength: 8)
                Text(state.locationsText)
                    .accessibilityLabel(state.locationsRecordedText)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if state.pointCount > 0 {
            Text(state.locationsRecordedText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Dynamic Island

/// ```
/// Stationary
/// ±7 m                                 38 locations
/// ```
///
/// Glanceable, not a diagnostics panel. The full picture is one tap away in the app.
private struct ExpandedDetail: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusLine(status: state.status, showsDetail: false)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let accuracy = state.accuracyText {
                    Text(accuracy)
                        .accessibilityLabel(state.spokenAccuracy ?? accuracy)
                }
                Spacer(minLength: 8)
                if state.pointCount > 0 {
                    Text(state.locationsText)
                        .accessibilityLabel(state.locationsRecordedText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if state.reducedAccuracy {
                ReducedAccuracyNote()
            }
        }
    }
}

// MARK: - Pieces

/// The recording dot, with the app's name where there is room for it.
///
/// Red, but never *only* red: the dot always travels with a word or, in the compact and
/// minimal presentations, with the location symbol that identifies GPeX.
private struct RecordingIndicator: View {
    let title: String?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isLuminanceReduced ? "location" : "location.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    // Shrink a little rather than truncate to "GPeX Recor…". The
                    // system adds its own Lock Screen margins on top of ours, so the
                    // available width is narrower than it looks.
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? RecordingText.lockScreenTitle)
    }
}

/// The elapsed timer.
///
/// Rendered and advanced *by the system* from the fixed `startedAt`, so no elapsed value
/// is ever sent through ActivityKit and nothing has to run to keep it ticking. This is the
/// single most important detail in the whole feature.
///
/// `timerInterval` rather than `Text(_:style: .timer)`: the style renders a coarse relative
/// phrase ("1 minute") on the Lock Screen, whereas this asks explicitly for a counting-up
/// clock with hours, which is what a multi-hour track needs — `1:42:18`.
private struct ElapsedTime: View {
    let startedAt: Date

    /// The interval must be finite: `Date.distantFuture` gives the timer no sane ideal
    /// width. A day is far longer than any photography session, and the in-app screen
    /// remains the exact elapsed time regardless.
    private static let longestPlausibleSession: TimeInterval = 24 * 60 * 60

    var body: some View {
        // No `.fixedSize()` here. A system-rendered timer's ideal width is large enough
        // that refusing to compress it overflows the Lock Screen row and the activity
        // renders as an empty capsule.
        Text(
            timerInterval: startedAt...startedAt.addingTimeInterval(Self.longestPlausibleSession),
            pauseTime: nil,
            countsDown: false,
            showsHours: true
        )
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// The status, in words and a symbol. Never colour alone.
private struct StatusLine: View {
    let status: RecordingLiveStatus
    let showsDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(status.title, systemImage: status.symbolName)
                .font(.subheadline.weight(.medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
            if showsDetail, let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A quiet warning, not an alarm. Recording is still working; the positions are coarser.
private struct ReducedAccuracyNote: View {
    var body: some View {
        Label(RecordingText.reducedAccuracyTitle, systemImage: RecordingText.reducedAccuracySymbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Previews

#if DEBUG
extension RecordingActivityAttributes {
    /// A recording that started 1:42:18 ago, so previews show a realistic timer.
    static var preview: RecordingActivityAttributes {
        RecordingActivityAttributes(
            sessionID: UUID(uuidString: "2B7F1C4E-0000-4000-8000-00000000BEEF")!,
            startedAt: Date(timeIntervalSinceNow: -6_138)
        )
    }
}

extension RecordingActivityAttributes.ContentState {
    static let acquiring = Self(status: .acquiringLocation)
    static let moving = Self(status: .moving, horizontalAccuracy: 6, pointCount: 41)
    static let stationary = Self(status: .stationary, horizontalAccuracy: 7, pointCount: 38)
    static let unavailable = Self(status: .temporarilyUnavailable, pointCount: 38)
    static let reduced = Self(
        status: .moving,
        horizontalAccuracy: 65,
        pointCount: 22,
        reducedAccuracy: true
    )
}

#Preview("Lock Screen", as: .content, using: RecordingActivityAttributes.preview) {
    RecordingLiveActivityWidget()
} contentStates: {
    RecordingActivityAttributes.ContentState.acquiring
    RecordingActivityAttributes.ContentState.moving
    RecordingActivityAttributes.ContentState.stationary
    RecordingActivityAttributes.ContentState.unavailable
    RecordingActivityAttributes.ContentState.reduced
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: RecordingActivityAttributes.preview) {
    RecordingLiveActivityWidget()
} contentStates: {
    RecordingActivityAttributes.ContentState.acquiring
    RecordingActivityAttributes.ContentState.moving
    RecordingActivityAttributes.ContentState.stationary
    RecordingActivityAttributes.ContentState.unavailable
    RecordingActivityAttributes.ContentState.reduced
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: RecordingActivityAttributes.preview) {
    RecordingLiveActivityWidget()
} contentStates: {
    RecordingActivityAttributes.ContentState.acquiring
    RecordingActivityAttributes.ContentState.moving
    RecordingActivityAttributes.ContentState.stationary
    RecordingActivityAttributes.ContentState.unavailable
    RecordingActivityAttributes.ContentState.reduced
}

#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: RecordingActivityAttributes.preview) {
    RecordingLiveActivityWidget()
} contentStates: {
    RecordingActivityAttributes.ContentState.moving
    RecordingActivityAttributes.ContentState.stationary
}
#endif
