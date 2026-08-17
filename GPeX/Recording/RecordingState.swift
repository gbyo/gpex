import Foundation
import Observation

/// What is happening while a recording is starting up.
nonisolated enum StartupPhase: Sendable, Equatable {
    /// The service session has been created and the system is asking the user.
    case waitingForAuthorization
    /// Authorized, but no usable fix has arrived yet.
    case acquiringLocation
}

/// What the photographer is doing, according to Core Location.
nonisolated enum RecordingActivity: Sendable, Equatable {
    case moving
    /// Core Location has automatically stopped delivering because the device is not
    /// moving. The recording is still active — this is not a pause.
    case stationary
    /// Core Location cannot currently determine a position.
    case temporarilyUnavailable
}

/// Why a recording could not start or could not continue.
nonisolated enum RecordingProblem: Sendable, Equatable {
    case locationServicesDisabled
    case permissionDenied
    case permissionRestricted
    /// Core Location suspended updates because the app is not sufficiently in use.
    case insufficientlyInUse
    /// The recovery marker pointed at a session that is no longer in the database.
    case recoveredSessionMissing
    case storageFailure(String)
}

/// The recording state machine.
///
/// The active Core Location objects live *inside* the non-idle cases, which makes
/// the dangerous states unrepresentable: there is no way to be recording without
/// retained sessions, and no way to hold sessions while idle.
enum RecordingState {
    case idle
    case starting(ActiveRecording, StartupPhase)
    case recording(ActiveRecording, RecordingActivity)
    case stopping(ActiveRecording)
    case failed(RecordingProblem)

    /// The in-flight recording, if any. `nil` exactly when idle or failed.
    var activeRecording: ActiveRecording? {
        switch self {
        case .starting(let active, _), .recording(let active, _), .stopping(let active):
            active
        case .idle, .failed:
            nil
        }
    }

    /// True while a recording exists and has not finished stopping.
    var isActive: Bool { activeRecording != nil }

    /// True once `stopRecording()` has begun, so a second tap does nothing.
    var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }
}

/// A flat, `Equatable` projection of `RecordingState` for views and tests.
///
/// Views never see the Core Location objects, and tests can assert on a simple value.
nonisolated enum RecordingPhase: Sendable, Equatable {
    case idle
    case waitingForAuthorization
    case acquiringLocation
    case moving
    case stationary
    case temporarilyUnavailable
    case stopping
    case failed(RecordingProblem)

    var isActive: Bool {
        switch self {
        case .idle, .failed: false
        case .waitingForAuthorization, .acquiringLocation, .moving, .stationary,
             .temporarilyUnavailable, .stopping: true
        }
    }
}

extension RecordingState {
    var phase: RecordingPhase {
        switch self {
        case .idle: .idle
        case .starting(_, .waitingForAuthorization): .waitingForAuthorization
        case .starting(_, .acquiringLocation): .acquiringLocation
        case .recording(_, .moving): .moving
        case .recording(_, .stationary): .stationary
        case .recording(_, .temporarilyUnavailable): .temporarilyUnavailable
        case .stopping: .stopping
        case .failed(let problem): .failed(problem)
        }
    }
}

/// Everything one in-flight recording owns.
///
/// Reference semantics are deliberate: the `RecordingState` cases carry this object,
/// and the strong references it holds are what keep the `CLServiceSession` and
/// `CLBackgroundActivitySession` alive for the whole recording — including while
/// Core Location reports the device stationary. Nothing here invalidates them when
/// `stationary` becomes true; only stopping the recording does.
///
/// `@Observable` so that live counters reach SwiftUI through
/// `RecordingCoordinator`'s computed properties.
@Observable
final class ActiveRecording {
    @ObservationIgnored let sessionID: UUID
    @ObservationIgnored let startedAt: Date

    /// The retained Core Location sessions. Released only by a stop or a failure.
    @ObservationIgnored let handles: any LocationSessionHandles

    /// The tasks consuming live updates and session diagnostics. Exactly one set
    /// exists per recording, which is what prevents duplicate live-update streams.
    @ObservationIgnored var tasks: [Task<Void, Never>] = []

    /// Resolves the SwiftData row for this recording. Samples wait on this before
    /// being persisted, so a fix that arrives before the row exists is never lost
    /// and never orphaned.
    @ObservationIgnored var sessionPreparation: Task<Void, any Error>?

    /// The newest timestamp already persisted, used to reject stale cached fixes.
    @ObservationIgnored var lastAcceptedTimestamp: Date?

    var persistedPointCount: Int = 0
    var latestSample: LocationSample?

    /// Precise Location is off for GPeX, per the service session diagnostics.
    var fullAccuracyDenied = false
    /// The background activity session reported it cannot currently continue.
    var backgroundActivityLimited = false

    /// True once at least one usable fix has been persisted.
    var hasUsableFix: Bool { persistedPointCount > 0 }

    init(sessionID: UUID, startedAt: Date, handles: any LocationSessionHandles) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.handles = handles
    }

    /// Stops consuming updates and diagnostics.
    func cancelStreams() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    /// Releases the Core Location sessions. The only place this happens.
    func releaseLocationSessions() {
        handles.invalidate()
    }

    /// Full cleanup, for a recording being abandoned rather than stopped.
    func tearDown() {
        cancelStreams()
        sessionPreparation?.cancel()
        sessionPreparation = nil
        releaseLocationSessions()
    }
}
