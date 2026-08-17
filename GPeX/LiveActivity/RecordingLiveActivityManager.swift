import Foundation
import OSLog

/// Keeps at most one Live Activity in step with a recording.
///
/// This object owns nothing that matters. It holds no recording state, no timer, no
/// background task, no Core Location and no SwiftData. It is handed a
/// `RecordingLiveSnapshot` when the user-visible recording state changes and it decides
/// whether ActivityKit needs to hear about it.
///
/// Every failure path is a log line and a return. A Live Activity that is disabled,
/// dismissed, refused or broken is a cosmetic problem; the GPX track is the product.
@MainActor
final class RecordingLiveActivityManager {
    private let host: any RecordingActivityHost

    /// The activity this manager owns. `nil` means there is nothing to update or end,
    /// which is also what makes `end()` idempotent.
    private var handle: (any RecordingActivityHandle)?
    private var sessionID: UUID?

    /// The last content handed to ActivityKit, so an unchanged snapshot costs nothing.
    private var lastSentState: RecordingActivityAttributes.ContentState?

    /// Serialises the async ActivityKit calls. Two purposes: updates are applied in the
    /// order they were decided, and the recording engine is never made to wait for
    /// ActivityKit. This is not a repeating timer and never schedules itself.
    private var pendingWork: Task<Void, Never>?

    init(host: any RecordingActivityHost = ActivityKitRecordingActivityHost()) {
        self.host = host
    }

    // MARK: - Start

    /// Starts the Live Activity for a recording the user just began.
    ///
    /// Non-throwing by design: the caller has already started recording and must not be
    /// able to fail because of this.
    func start(_ snapshot: RecordingLiveSnapshot) {
        guard handle == nil else {
            // One recording, one activity. A second start would orphan the first.
            Log.recording.error("Refusing to start a second Live Activity for one recording")
            return
        }
        // Anything left over from an earlier session belongs to no live recording.
        endActivities(host.existingActivities())
        create(snapshot)
    }

    // MARK: - Update

    /// Sends the snapshot to ActivityKit if — and only if — it would change what is shown.
    ///
    /// Safe and cheap to call after any state change. There is no polling here: the
    /// elapsed timer is rendered by the system from `startedAt`, so nothing needs to be
    /// sent as time passes.
    func update(_ snapshot: RecordingLiveSnapshot) {
        guard let handle, snapshot.sessionID == sessionID else { return }
        guard let state = snapshot.contentState else { return }
        // The whole point of the budget-conscious design: identical content is not sent.
        guard state != lastSentState else { return }
        lastSentState = state
        enqueue { await handle.update(state: state) }
    }

    // MARK: - Reconcile

    /// Reassociates with the Live Activity belonging to a restored recording.
    ///
    /// Matching is by `sessionID` read from the activity's static attributes, never by
    /// taking whichever activity comes first.
    ///
    /// - Parameter creatingIfMissing: whether to create one when no match exists. `false`
    ///   when Core Location relaunched the app in the background — the GPS track is
    ///   authoritative and recovery must not depend on ActivityKit. `true` once the user
    ///   has brought GPeX to the foreground with a recording still running, where
    ///   putting the Lock Screen projection back is a courtesy that costs nothing.
    func reconcile(with snapshot: RecordingLiveSnapshot, creatingIfMissing: Bool) {
        guard sessionID == nil || sessionID == snapshot.sessionID else {
            Log.lifecycle.error("Live Activity reconciliation asked about a different recording")
            return
        }
        // Already associated: nothing to find, just catch the content up.
        //
        // This is also what happens when the user has swiped the activity away. ActivityKit
        // makes further updates to it no-ops, and that is the right outcome: a dismissal is
        // a decision, and pushing the activity back onto the Lock Screen every time the app
        // is opened would be obnoxious. The recording is unaffected either way.
        if handle != nil {
            update(snapshot)
            return
        }

        let existing = host.existingActivities()
        if let match = existing.first(where: { $0.sessionID == snapshot.sessionID }) {
            handle = match
            sessionID = snapshot.sessionID
            // Unknown: this activity's content was set by a process that is now gone.
            lastSentState = nil
            Log.lifecycle.notice("Reassociated the Live Activity for \(snapshot.sessionID, privacy: .public)")
            update(snapshot)
            // Everything except the one just adopted, by identity rather than by session
            // id, so even a duplicate claiming this session cannot survive.
            endActivities(existing)
            return
        }

        endActivities(existing)
        if creatingIfMissing {
            create(snapshot)
        } else {
            Log.lifecycle.info("No Live Activity to rejoin; the recording continues regardless")
        }
    }

    // MARK: - End

    /// Ends the Live Activity for a recording that has finished, failed or been abandoned.
    ///
    /// Idempotent, and correct when there was never an activity at all. Awaited by the
    /// coordinator only *after* the recording itself has shut down, so nothing about
    /// stopping depends on ActivityKit answering.
    func end() async {
        if let handle {
            self.handle = nil
            sessionID = nil
            lastSentState = nil
            enqueue { await handle.end() }
        }
        await pendingWork?.value
    }

    // MARK: - Internals

    private func create(_ snapshot: RecordingLiveSnapshot) {
        guard let state = snapshot.contentState else { return }
        guard host.areActivitiesEnabled else {
            Log.recording.notice("Live Activities are off; recording without one")
            return
        }
        do {
            handle = try host.request(attributes: snapshot.attributes, state: state)
            sessionID = snapshot.sessionID
            lastSentState = state
            Log.recording.notice("Started the Live Activity for \(snapshot.sessionID, privacy: .public)")
        } catch {
            // Recording is already under way and stays that way.
            Log.recording.error(
                "Could not start the Live Activity: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func endActivities(_ activities: [any RecordingActivityHandle]) {
        for activity in activities where activity !== handle {
            Log.recording.notice("Ending a leftover Live Activity")
            enqueue { await activity.end() }
        }
    }

    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await operation()
        }
    }
}

extension RecordingLiveActivityManager {
    /// Awaits the serialised ActivityKit work.
    ///
    /// Exists so tests can assert on what was sent without sleeping. Production code has
    /// no reason to wait for a Lock Screen.
    func flushPendingWork() async {
        await pendingWork?.value
    }
}
