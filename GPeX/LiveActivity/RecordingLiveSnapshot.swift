import Foundation

/// The read-only projection of a recording that the Live Activity is allowed to see.
///
/// `RecordingCoordinator` builds one of these and hands it over. Deliberately a flat
/// `Equatable` value: the manager never receives an `ActiveRecording`, a `LocationSample`,
/// a `CLServiceSession` or anything else that could let the Lock Screen reach into the
/// recording engine. Dependencies point one way only.
nonisolated struct RecordingLiveSnapshot: Sendable, Equatable {
    var sessionID: UUID
    var startedAt: Date
    var phase: RecordingPhase
    /// Metres, from the most recently accepted fix. `nil` before the first one.
    var horizontalAccuracy: Double?
    /// The count GPeX has persisted, which is the authoritative one.
    var pointCount: Int
    var reducedAccuracy: Bool

    init(
        sessionID: UUID,
        startedAt: Date,
        phase: RecordingPhase,
        horizontalAccuracy: Double? = nil,
        pointCount: Int = 0,
        reducedAccuracy: Bool = false
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.phase = phase
        self.horizontalAccuracy = horizontalAccuracy
        self.pointCount = pointCount
        self.reducedAccuracy = reducedAccuracy
    }
}

extension RecordingLiveSnapshot {
    var attributes: RecordingActivityAttributes {
        RecordingActivityAttributes(sessionID: sessionID, startedAt: startedAt)
    }

    /// The ActivityKit content for this snapshot, or `nil` when the phase is not one a
    /// Live Activity should represent.
    ///
    /// Note what is *not* here: no elapsed seconds. The system renders the timer from
    /// `startedAt`, so nothing has to wake the app to advance a clock.
    var contentState: RecordingActivityAttributes.ContentState? {
        guard let status = RecordingLiveStatus(phase: phase) else { return nil }
        return RecordingActivityAttributes.ContentState(
            status: status,
            // Dropped rather than shown stale when the status says there is no current fix.
            horizontalAccuracy: status.showsAccuracy ? horizontalAccuracy : nil,
            pointCount: pointCount,
            reducedAccuracy: reducedAccuracy
        )
    }
}

extension RecordingLiveStatus {
    /// Maps a recording phase onto what the Lock Screen should say.
    ///
    /// `nil` for `idle` and `failed`: neither is a recording in progress, and both are
    /// already reported inside the app. A finished or failed recording gets its Live
    /// Activity ended, not relabelled.
    init?(phase: RecordingPhase) {
        switch phase {
        case .waitingForAuthorization: self = .waitingForAuthorization
        case .acquiringLocation: self = .acquiringLocation
        case .moving: self = .moving
        case .stationary: self = .stationary
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .stopping: self = .stopping
        case .idle, .failed: return nil
        }
    }
}
