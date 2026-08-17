// `@preconcurrency` because ActivityKit has not been audited for Swift 6 concurrency:
// `Activity` is not `Sendable`, yet `update` and `end` are `@concurrent`, so there is no
// way to call the framework's own supported API from an isolated context without it. The
// attribute is confined to this one file — the seam that exists precisely so ActivityKit
// touches nothing else.
@preconcurrency import ActivityKit
import Foundation

/// One Live Activity, reduced to the three things the manager does with it.
@MainActor
protocol RecordingActivityHandle: AnyObject {
    /// The recording this activity was created for, read back from its static attributes.
    /// This is what makes reassociation after a relaunch exact rather than a guess.
    var sessionID: UUID { get }
    func update(state: RecordingActivityAttributes.ContentState) async
    func end() async
}

/// The seam over ActivityKit's static API.
///
/// Narrow on purpose. Everything above this protocol is plain values and is unit tested;
/// everything below it is a direct call into `Activity<RecordingActivityAttributes>` and
/// is exercised on a device. Abstracting more than this would mean pretending to test
/// ActivityKit itself.
@MainActor
protocol RecordingActivityHost {
    /// False when the user has turned Live Activities off. Recording does not care.
    var areActivitiesEnabled: Bool { get }

    func request(
        attributes: RecordingActivityAttributes,
        state: RecordingActivityAttributes.ContentState
    ) throws -> any RecordingActivityHandle

    /// Every Live Activity of this kind the system currently knows about, including ones
    /// created before this process launched.
    func existingActivities() -> [any RecordingActivityHandle]
}

// MARK: - The real thing

struct ActivityKitRecordingActivityHost: RecordingActivityHost {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(
        attributes: RecordingActivityAttributes,
        state: RecordingActivityAttributes.ContentState
    ) throws -> any RecordingActivityHandle {
        let activity = try Activity<RecordingActivityAttributes>.request(
            attributes: attributes,
            content: ActivityKitRecordingActivityHost.content(for: state),
            // No APNs. GPeX has no backend, requests no push capability, and does
            // not ask for a frequent-update budget.
            pushType: nil
        )
        return Handle(activity: activity)
    }

    func existingActivities() -> [any RecordingActivityHandle] {
        Activity<RecordingActivityAttributes>.activities.map { Handle(activity: $0) }
    }

    /// `staleDate` is deliberately `nil`.
    ///
    /// GPeX is event-driven: Core Location goes quiet on purpose while the
    /// photographer stands still, sometimes for hours, and the app does not wake up to
    /// say so. Any stale date would therefore mark a perfectly healthy recording as
    /// stale during exactly the situation this app is built around.
    static func content(
        for state: RecordingActivityAttributes.ContentState
    ) -> ActivityContent<RecordingActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }

    private final class Handle: RecordingActivityHandle {
        private let activity: Activity<RecordingActivityAttributes>

        init(activity: Activity<RecordingActivityAttributes>) {
            self.activity = activity
        }

        var sessionID: UUID { activity.attributes.sessionID }

        func update(state: RecordingActivityAttributes.ContentState) async {
            await activity.update(ActivityKitRecordingActivityHost.content(for: state))
        }

        /// Immediate dismissal: a finished recording is finished, and leaving
        /// "Recording Complete" on the Lock Screen for hours is clutter, not information.
        func end() async {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
