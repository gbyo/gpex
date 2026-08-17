import Foundation
import Observation
import OSLog

/// Owns the recording state machine, the retained Core Location sessions, and the
/// tasks consuming live updates.
///
/// Everything here runs on the main actor. Location updates arrive a few times a
/// minute at most, so there is nothing to gain from another executor, and keeping one
/// isolation domain removes every opportunity for two live-update streams to exist at
/// once. Persistence hops to `TrackStore`, which has its own.
@Observable
final class RecordingCoordinator {
    /// A fix older than the recording start by more than this is treated as a cached
    /// location rather than an observation of this session.
    private static let clockJitterTolerance: TimeInterval = 5
    /// How recent a point must be for a location-less stationary report to apply to it.
    private static let stationaryBackfillWindow: TimeInterval = 120

    private let trackStore: TrackStore
    private let markerStore: RecoveryMarkerStore
    private let provider: any LocationUpdatesProvider
    private let now: () -> Date
    /// Whether this process should rejoin an outstanding recording on launch. Decided by
    /// the composition root, so a unit-test host never resurrects a recording behind a
    /// test's back.
    private let allowsRestore: Bool

    private(set) var state: RecordingState = .idle

    /// Set when a recording finishes, so the UI can show the completed session.
    private(set) var lastFinishedSessionID: UUID?

    init(
        trackStore: TrackStore,
        markerStore: RecoveryMarkerStore,
        provider: any LocationUpdatesProvider,
        allowsRestore: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) {
        self.trackStore = trackStore
        self.markerStore = markerStore
        self.provider = provider
        self.allowsRestore = allowsRestore
        self.now = now
    }

    // MARK: - Observable projections

    var phase: RecordingPhase { state.phase }
    var startedAt: Date? { state.activeRecording?.startedAt }
    var recordedPointCount: Int { state.activeRecording?.persistedPointCount ?? 0 }
    var latestSample: LocationSample? { state.activeRecording?.latestSample }
    /// Precise Location is off for PhotoTrack while this recording runs.
    var isPreciseLocationDenied: Bool { state.activeRecording?.fullAccuracyDenied ?? false }
    /// Core Location reported that the background activity cannot currently continue.
    var isBackgroundActivityLimited: Bool { state.activeRecording?.backgroundActivityLimited ?? false }

    // MARK: - Start

    /// Begins a recording in response to the user tapping Start.
    ///
    /// Ordering matters and is deliberate:
    /// 1. the recovery marker, so a crash in the next millisecond is still recoverable;
    /// 2. the `CLServiceSession` and `CLBackgroundActivitySession`, whose creation is
    ///    what asks the user for When In Use and temporary full accuracy;
    /// 3. the SwiftData row;
    /// 4. the live-update stream.
    ///
    /// The session start time is recorded immediately, without waiting for a fix.
    func startRecording() async {
        // A second tap, or a tap while restoring, must not create a second recording.
        guard !state.isActive else { return }

        let startedAt = now()
        let sessionID = UUID()
        let name = Self.defaultSessionName(for: startedAt)

        markerStore.save(RecoveryMarker(sessionID: sessionID, startedAt: startedAt))

        let active = ActiveRecording(
            sessionID: sessionID,
            startedAt: startedAt,
            handles: provider.beginSessions()
        )
        state = .starting(active, .waitingForAuthorization)
        Log.recording.notice("Started recording \(sessionID, privacy: .public)")

        active.sessionPreparation = Task { [trackStore] in
            try await trackStore.createSession(id: sessionID, name: name, startedAt: startedAt)
        }
        beginStreams(for: active)

        // Report a storage failure rather than appearing to record into nothing.
        do {
            try await active.sessionPreparation?.value
        } catch is CancellationError {
            // Stopped or abandoned while starting; nothing to report.
        } catch {
            Log.recording.error("Could not create session: \(error.localizedDescription, privacy: .public)")
            await failRecording(active, problem: .storageFailure(error.localizedDescription))
        }
    }

    // MARK: - Restore

    /// Rejoins an interrupted recording. Called from
    /// `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Synchronous on purpose. Core Location expects a process it relaunched to express
    /// renewed interest promptly, so the sessions and the update stream are recreated
    /// before any `await`. Resolving the SwiftData row happens afterwards, and points
    /// wait on that resolution rather than being buffered in memory.
    ///
    /// A force-quit is not background recording, and this does not pretend otherwise:
    /// nothing was recorded while the process was gone, and the resulting gap is left
    /// in the data.
    func restoreInterruptedRecordingIfNeeded() {
        guard allowsRestore else { return }
        // Restoring twice would create a second live-update stream for one recording.
        guard !state.isActive else { return }
        guard let marker = markerStore.load() else { return }

        Log.lifecycle.notice("Restoring recording \(marker.sessionID, privacy: .public)")

        let active = ActiveRecording(
            sessionID: marker.sessionID,
            startedAt: marker.startedAt,
            handles: provider.beginSessions()
        )
        state = .starting(active, .acquiringLocation)

        active.sessionPreparation = Task { [trackStore] in
            try await trackStore.requireOpenSession(id: marker.sessionID)
        }
        beginStreams(for: active)

        Task { await completeRestore(active) }
    }

    private func completeRestore(_ active: ActiveRecording) async {
        do {
            try await active.sessionPreparation?.value
            guard isCurrent(active) else { return }
            let existing = try await trackStore.pointCount(sessionID: active.sessionID)
            guard isCurrent(active) else { return }
            active.persistedPointCount = existing
            Log.lifecycle.notice("Rejoined recording with \(existing, privacy: .public) existing points")
        } catch is CancellationError {
            // Stopped while restoring.
        } catch TrackStoreError.sessionAlreadyEnded {
            // Stop finished writing the end time but the process died before the marker
            // was cleared. Finish that cleanup instead of resurrecting the recording.
            Log.lifecycle.notice("Marker outlived a completed stop; clearing it")
            abandon(active, problem: nil)
        } catch {
            // The marker points at a session that is no longer there. Do not invent one.
            Log.lifecycle.error("Could not rejoin recording: \(error.localizedDescription, privacy: .public)")
            abandon(active, problem: .recoveredSessionMissing)
        }
    }

    // MARK: - Stop

    /// Ends the recording. Idempotent — a second tap while stopping does nothing.
    func stopRecording() async {
        guard let active = state.activeRecording, !state.isStopping else { return }
        let endedAt = now()
        state = .stopping(active)

        // Stop the flow of data before writing the end time, so no observation can be
        // persisted with a timestamp after the recording officially ended.
        active.cancelStreams()
        active.releaseLocationSessions()

        // Let an in-flight row creation finish; otherwise a Start immediately followed
        // by a Stop would leave nothing to close.
        _ = try? await active.sessionPreparation?.value
        active.sessionPreparation = nil

        do {
            try await trackStore.endSession(id: active.sessionID, endedAt: endedAt)
        } catch {
            Log.recording.error("Could not close session: \(error.localizedDescription, privacy: .public)")
        }

        markerStore.clear()
        lastFinishedSessionID = active.sessionID
        state = .idle
        Log.recording.notice("Stopped recording \(active.sessionID, privacy: .public)")
    }

    func clearLastFinishedSession() {
        lastFinishedSessionID = nil
    }

    /// Dismisses a failure so the home screen can offer Start again.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: - Streams

    private func beginStreams(for active: ActiveRecording) {
        // The single guarantee that one recording never has two live-update streams.
        guard active.tasks.isEmpty else {
            Log.recording.error("Refusing to start a second live-update stream")
            return
        }
        let updates = provider.liveUpdates()
        let diagnostics = active.handles.diagnostics()
        active.tasks = [
            Task { await self.consumeUpdates(updates, for: active) },
            Task { await self.consumeDiagnostics(diagnostics, for: active) },
        ]
    }

    private func consumeUpdates(
        _ updates: AsyncThrowingStream<LocationUpdateEvent, any Error>,
        for active: ActiveRecording
    ) async {
        do {
            for try await event in updates {
                guard isCurrent(active) else { return }
                await handle(event, for: active)
            }
            Log.recording.info("Live update stream finished")
        } catch is CancellationError {
            // Expected on stop.
        } catch {
            Log.recording.error("Live update stream failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consumeDiagnostics(
        _ diagnostics: AsyncStream<SessionDiagnostic>,
        for active: ActiveRecording
    ) async {
        for await diagnostic in diagnostics {
            guard isCurrent(active) else { return }
            await handle(diagnostic, for: active)
        }
    }

    // MARK: - Event handling

    private func handle(_ event: LocationUpdateEvent, for active: ActiveRecording) async {
        if event.authorizationDeniedGlobally {
            await failRecording(active, problem: .locationServicesDisabled)
            return
        }
        if event.authorizationDenied {
            await failRecording(active, problem: .permissionDenied)
            return
        }
        if event.authorizationRestricted {
            await failRecording(active, problem: .permissionRestricted)
            return
        }

        if event.accuracyLimited { active.fullAccuracyDenied = true }
        if event.insufficientlyInUse { active.backgroundActivityLimited = true }

        if let sample = event.sample {
            await persist(sample, for: active)
        } else if event.stationary {
            // A stationary report with no coordinate is still a real statement about
            // where the device already is.
            await recordStationaryAtLastKnownPosition(for: active)
        }

        guard isCurrent(active) else { return }
        applyActivity(from: event, for: active)
    }

    private func handle(_ diagnostic: SessionDiagnostic, for active: ActiveRecording) async {
        if diagnostic.authorizationDeniedGlobally {
            await failRecording(active, problem: .locationServicesDisabled)
            return
        }
        if diagnostic.authorizationDenied {
            await failRecording(active, problem: .permissionDenied)
            return
        }
        if diagnostic.authorizationRestricted {
            await failRecording(active, problem: .permissionRestricted)
            return
        }

        guard isCurrent(active) else { return }

        // Reduced accuracy is not a failure: PhotoTrack keeps recording and says so.
        active.fullAccuracyDenied = diagnostic.fullAccuracyDenied
        active.backgroundActivityLimited = diagnostic.insufficientlyInUse

        if diagnostic.authorizationRequestInProgress {
            setStartupPhase(.waitingForAuthorization, for: active)
        } else if case .starting(_, .waitingForAuthorization) = state {
            setStartupPhase(.acquiringLocation, for: active)
        }

        if diagnostic.serviceSessionRequired {
            Log.recording.error("Core Location wants an explicit service session")
        }
    }

    private func applyActivity(from event: LocationUpdateEvent, for active: ActiveRecording) {
        // Until a usable fix exists, the honest status is still "acquiring".
        guard active.hasUsableFix else {
            if case .starting(_, .waitingForAuthorization) = state,
               !event.authorizationRequestInProgress {
                setStartupPhase(.acquiringLocation, for: active)
            }
            return
        }

        let activity: RecordingActivity
        if event.locationUnavailable {
            activity = .temporarilyUnavailable
        } else if event.stationary {
            activity = .stationary
        } else {
            activity = .moving
        }
        setActivity(activity, for: active)
    }

    // MARK: - Persistence

    private func persist(_ sample: LocationSample, for active: ActiveRecording) async {
        guard let accepted = validate(sample, for: active) else { return }
        do {
            // Wait for the row to exist. Cheap in practice, and it means a fix that
            // arrives before the session is written is neither dropped nor orphaned.
            try await active.sessionPreparation?.value
            let total = try await trackStore.append([accepted], sessionID: active.sessionID)
            guard isCurrent(active) else { return }
            active.lastAcceptedTimestamp = accepted.timestamp
            active.latestSample = accepted
            active.persistedPointCount = total
            Log.recording.logCoordinateForDebugging(
                "persisted fix",
                latitude: accepted.latitude,
                longitude: accepted.longitude
            )
        } catch is CancellationError {
            // Stopped mid-write.
        } catch TrackStoreError.sessionNotFound {
            Log.recording.error("Session vanished; abandoning recording rather than writing orphans")
            abandon(active, problem: .recoveredSessionMissing)
        } catch {
            Log.recording.error("Could not persist fix: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Contextual validation, on top of the intrinsic checks in `LocationSample`.
    ///
    /// Rejects only fixes that cannot belong to this recording. Mediocre accuracy is
    /// kept: a poor fix is more useful than no fix, and the exporter can prefer better
    /// ones later.
    private func validate(_ sample: LocationSample, for active: ActiveRecording) -> LocationSample? {
        let tolerance = Self.clockJitterTolerance
        guard sample.timestamp >= active.startedAt.addingTimeInterval(-tolerance) else {
            Log.recording.debug("Rejected a fix predating the recording")
            return nil
        }
        guard sample.timestamp <= now().addingTimeInterval(tolerance) else {
            Log.recording.debug("Rejected a fix timestamped in the future")
            return nil
        }
        if let last = active.lastAcceptedTimestamp, sample.timestamp <= last {
            Log.recording.debug("Rejected a fix no newer than the last accepted one")
            return nil
        }
        return sample
    }

    private func recordStationaryAtLastKnownPosition(for active: ActiveRecording) async {
        let cutoff = now().addingTimeInterval(-Self.stationaryBackfillWindow)
        do {
            _ = try await trackStore.markLatestPointStationary(
                sessionID: active.sessionID,
                notOlderThan: cutoff
            )
        } catch {
            Log.recording.error("Could not record stationary state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Failure and cleanup

    /// Ends a recording that cannot continue.
    ///
    /// A start that never captured a fix is rolled back, so a denied permission does
    /// not leave an empty session behind. A recording that captured anything is closed,
    /// never discarded.
    private func failRecording(_ active: ActiveRecording, problem: RecordingProblem) async {
        guard isCurrent(active), !state.isStopping else { return }
        Log.recording.error("Recording failed: \(String(describing: problem), privacy: .public)")

        active.cancelStreams()
        active.releaseLocationSessions()
        _ = try? await active.sessionPreparation?.value
        active.sessionPreparation = nil

        if active.persistedPointCount == 0 {
            try? await trackStore.deleteSession(id: active.sessionID)
        } else {
            try? await trackStore.endSession(id: active.sessionID, endedAt: now())
        }

        markerStore.clear()
        guard isCurrent(active), !state.isStopping else { return }
        state = .failed(problem)
    }

    /// Drops a recording that turned out not to exist, without touching stored data.
    private func abandon(_ active: ActiveRecording, problem: RecordingProblem?) {
        guard isCurrent(active) else { return }
        active.tearDown()
        markerStore.clear()
        state = problem.map { RecordingState.failed($0) } ?? .idle
    }

    // MARK: - State helpers

    private func isCurrent(_ active: ActiveRecording) -> Bool {
        state.activeRecording === active
    }

    private func setStartupPhase(_ startupPhase: StartupPhase, for active: ActiveRecording) {
        guard isCurrent(active) else { return }
        if case .starting(_, let current) = state, current == startupPhase { return }
        guard case .starting = state else { return }
        state = .starting(active, startupPhase)
    }

    private func setActivity(_ activity: RecordingActivity, for active: ActiveRecording) {
        guard isCurrent(active), !state.isStopping else { return }
        if case .recording(_, let current) = state, current == activity { return }
        state = .recording(active, activity)
    }

    // MARK: - Naming

    /// A neutral default name, so Start never has to interrupt with a naming dialog.
    static func defaultSessionName(for date: Date) -> String {
        "Photo Session — \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
