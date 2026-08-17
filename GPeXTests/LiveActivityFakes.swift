import Foundation
import Testing
@testable import GPeX

/// A stand-in for ActivityKit.
///
/// The seam it implements is deliberately tiny — request, list, and per-activity
/// update/end — which is why the whole feature above it can be tested without a device
/// and without pretending to test ActivityKit itself.
@MainActor
final class FakeActivityHost: RecordingActivityHost {
    var areActivitiesEnabled = true

    /// Set to make `request` throw, standing in for ActivityKit refusing.
    var requestError: (any Error)?

    /// Activities the system already knows about, as after a relaunch.
    var preexisting: [FakeActivityHandle] = []

    private(set) var requested: [RecordingActivityAttributes] = []
    private(set) var created: [FakeActivityHandle] = []

    func request(
        attributes: RecordingActivityAttributes,
        state: RecordingActivityAttributes.ContentState
    ) throws -> any RecordingActivityHandle {
        if let requestError { throw requestError }
        requested.append(attributes)
        let handle = FakeActivityHandle(sessionID: attributes.sessionID, initialState: state)
        created.append(handle)
        return handle
    }

    func existingActivities() -> [any RecordingActivityHandle] {
        preexisting
    }
}

@MainActor
final class FakeActivityHandle: RecordingActivityHandle {
    let sessionID: UUID

    /// Every content state this activity has been given, in order, starting with the one
    /// it was created with.
    private(set) var states: [RecordingActivityAttributes.ContentState] = []
    private(set) var endCount = 0

    init(sessionID: UUID, initialState: RecordingActivityAttributes.ContentState? = nil) {
        self.sessionID = sessionID
        if let initialState { states.append(initialState) }
    }

    func update(state: RecordingActivityAttributes.ContentState) async {
        states.append(state)
    }

    func end() async {
        endCount += 1
    }
}

extension FakeActivityHandle {
    var latestState: RecordingActivityAttributes.ContentState? { states.last }
    var isEnded: Bool { endCount > 0 }
}

nonisolated struct ActivityKitRefused: Error {}

// MARK: - Snapshot building

@MainActor
extension RecordingLiveSnapshot {
    /// A snapshot with everything but the interesting field defaulted.
    static func fixture(
        sessionID: UUID = UUID(),
        startedAt: Date = testBase,
        phase: RecordingPhase = .moving,
        horizontalAccuracy: Double? = 7,
        pointCount: Int = 38,
        reducedAccuracy: Bool = false
    ) -> RecordingLiveSnapshot {
        RecordingLiveSnapshot(
            sessionID: sessionID,
            startedAt: startedAt,
            phase: phase,
            horizontalAccuracy: horizontalAccuracy,
            pointCount: pointCount,
            reducedAccuracy: reducedAccuracy
        )
    }
}
