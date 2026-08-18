import Foundation
import Testing
@testable import GPeX

@Suite("Recording state management")
@MainActor
struct RecordingCoordinatorTests {

    // MARK: - Starting

    @Test("Starting records the session immediately, before any fix arrives")
    func startAnchorsTimeBeforeFirstFix() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        #expect(harness.coordinator.phase.isActive)
        #expect(harness.coordinator.startedAt == harness.clock.now)
        #expect(harness.coordinator.recordedPointCount == 0)

        // The row exists with a start time already, even with no location yet.
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.startedAt == harness.clock.now)
        #expect(snapshot.endedAt == nil)
    }

    @Test("The status stays honest until a usable fix exists")
    func acquiringUntilFirstFix() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        // A diagnostic saying nothing is wrong moves it off "waiting for permission".
        harness.provider.emit(SessionDiagnostic(source: .serviceSession))
        try await waitUntil("acquiring") { harness.coordinator.phase == .acquiringLocation }

        harness.deliver(sample(1))
        try await waitUntil("recording") { harness.coordinator.phase == .tracking }
        #expect(harness.coordinator.recordedPointCount == 1)
    }

    @Test("A second Start cannot create a second recording")
    func cannotStartTwoSessions() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let first = try #require(harness.coordinator.state.activeRecording?.sessionID)

        await harness.coordinator.startRecording()
        await harness.coordinator.startRecording()

        #expect(harness.coordinator.state.activeRecording?.sessionID == first)
        // The decisive assertions: one set of Core Location objects, one stream.
        #expect(harness.provider.sessionsCreated == 1)
        #expect(harness.provider.liveUpdateStreamsCreated == 1)
    }

    @Test("A default name is generated so Start never asks a question")
    func generatesDefaultName() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.name == RecordingCoordinator.defaultSessionName(for: harness.clock.now))
        #expect(!snapshot.name.isEmpty)
    }

    // MARK: - Tracking and stationary

    @Test("Stationary is reported as recording, never as paused")
    func stationaryIsStillRecording() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        harness.deliver(sample(2, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        #expect(harness.coordinator.phase.isActive)
        #expect(harness.coordinator.phase.headline == "Recording")
        #expect(harness.coordinator.phase.activityTitle == "Stationary")
        #expect(harness.coordinator.phase.activityDetail == "Saving battery")
    }

    @Test("Going stationary does not release the background activity session")
    func stationaryKeepsSessionsAlive() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        harness.deliver(sample(2, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        // The whole automatic-resume behaviour depends on this staying alive.
        #expect(harness.provider.sessionsOutstanding == 1)

        // And it resumes by itself when movement returns, with no new stream.
        harness.deliver(sample(700, positionB))
        try await waitUntil("resumed") { harness.coordinator.phase == .tracking }
        #expect(harness.provider.liveUpdateStreamsCreated == 1)
        #expect(harness.provider.sessionsOutstanding == 1)
    }

    @Test("A stationary report with no coordinate marks the last known position")
    func stationaryWithoutLocation() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.provider.emitStationaryWithoutLocation()
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        // No fabricated point: the existing one is simply now known to be stationary.
        // The write completes before the phase changes, so this needs no further wait.
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
        #expect(try await harness.store.samples(sessionID: sessionID).first?.stationary == true)
    }

    @Test("Unavailable location is surfaced without ending the recording")
    func temporarilyUnavailable() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        var event = LocationUpdateEvent(sample: nil)
        event.locationUnavailable = true
        harness.provider.emit(event)

        try await waitUntil("unavailable") { harness.coordinator.phase == .temporarilyUnavailable }
        #expect(harness.coordinator.phase.isActive)
        #expect(harness.provider.sessionsOutstanding == 1)
    }

    // MARK: - Validation

    @Test("A cached fix from before the recording is rejected")
    func rejectsStaleCachedFix() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        // A location from an hour ago, the classic first cached delivery.
        harness.deliver(sample(-3_600))
        harness.deliver(sample(1))
        try await waitUntil("one accepted fix") { harness.coordinator.recordedPointCount == 1 }

        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.count == 1)
        #expect(samples[0].timestamp == testBase.addingTimeInterval(1))
    }

    @Test("A fix no newer than the last accepted one is rejected")
    func rejectsNonAdvancingFix() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(10))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.deliver(sample(10))
        harness.deliver(sample(5))
        harness.deliver(sample(20, positionB))
        try await waitUntil("second fix") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.recordedPointCount == 2)
    }

    // MARK: - Stopping

    @Test("Stopping closes the session and releases everything")
    func stopReleasesEverything() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.clock.advance(1_800)
        await harness.coordinator.stopRecording()

        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.state.activeRecording == nil)
        // Stop is the only thing that may invalidate the Core Location sessions.
        #expect(harness.provider.sessionsOutstanding == 0)
        #expect(harness.coordinator.lastFinishedSessionID == sessionID)

        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt == harness.clock.now)
    }

    @Test("Stop is idempotent")
    func stopIsIdempotent() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.clock.advance(600)
        let expectedEnd = harness.clock.now

        await harness.coordinator.stopRecording()
        harness.clock.advance(600)
        await harness.coordinator.stopRecording()
        await harness.coordinator.stopRecording()

        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt == expectedEnd)
        #expect(harness.provider.sessionsOutstanding == 0)
        #expect(harness.coordinator.phase == .idle)
    }

    @Test("Start immediately followed by Stop still leaves a closed session")
    func immediateStopStillCloses() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        await harness.coordinator.stopRecording()

        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt != nil)
    }

    @Test("No point is persisted after the recording has stopped")
    func noPointsAfterStop() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        await harness.coordinator.stopRecording()
        harness.deliver(sample(2, positionB))
        harness.deliver(sample(3, positionC))
        try await Task.sleep(for: .milliseconds(50))

        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
    }

    // MARK: - Recovery marker

    @Test("The recovery marker exists only while a recording is active")
    func markerLifecycle() async throws {
        let harness = try RecordingHarness()
        #expect(harness.markerStore.load() == nil)

        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let marker = try #require(harness.markerStore.load())
        #expect(marker.sessionID == sessionID)
        #expect(marker.startedAt == harness.clock.now)

        await harness.coordinator.stopRecording()
        #expect(harness.markerStore.load() == nil)
    }

    @Test("A half-written marker is discarded rather than trusted")
    func inconsistentMarkerIsDiscarded() throws {
        let harness = try RecordingHarness()
        harness.defaults.set(true, forKey: RecoveryMarkerStore.recordingRequestedKey)
        // No session id or start date written.
        #expect(harness.markerStore.load() == nil)
        #expect(harness.defaults.bool(forKey: RecoveryMarkerStore.recordingRequestedKey) == false)
    }

    // MARK: - Restoring

    @Test("An interrupted recording is rejoined and its data preserved")
    func restoresInterruptedRecording() async throws {
        let first = try RecordingHarness()
        await first.coordinator.startRecording()
        let sessionID = try #require(first.coordinator.state.activeRecording?.sessionID)
        first.deliver(sample(1))
        first.deliver(sample(30, positionB))
        try await waitUntil("two fixes") { first.coordinator.recordedPointCount == 2 }

        // Simulate a relaunch: a fresh coordinator over the same store and marker.
        let provider = TestLocationUpdatesProvider()
        let clock = MutableClock(testBase.addingTimeInterval(900))
        let restored = RecordingCoordinator(
            trackStore: first.store,
            markerStore: first.markerStore,
            provider: provider,
            now: { clock.now }
        )

        restored.restoreInterruptedRecordingIfNeeded()

        // Core Location is rejoined synchronously, before any await.
        #expect(provider.sessionsCreated == 1)
        #expect(provider.liveUpdateStreamsCreated == 1)
        #expect(restored.phase.isActive)
        #expect(restored.startedAt == testBase)

        try await waitUntil("existing points counted") { restored.recordedPointCount == 2 }

        // Recording continues into the same session; the gap is simply a gap.
        clock.now = testBase.addingTimeInterval(900)
        provider.emit(sample(900, positionC))
        try await waitUntil("third fix") { restored.recordedPointCount == 3 }

        let samples = try await first.store.samples(sessionID: sessionID)
        #expect(samples.map { $0.timestamp.timeIntervalSince(testBase) } == [1, 30, 900])
    }

    @Test("Restoring twice does not create a second stream")
    func restoresOnlyOnce() async throws {
        let first = try RecordingHarness()
        await first.coordinator.startRecording()

        let provider = TestLocationUpdatesProvider()
        let restored = RecordingCoordinator(
            trackStore: first.store,
            markerStore: first.markerStore,
            provider: provider
        )

        restored.restoreInterruptedRecordingIfNeeded()
        restored.restoreInterruptedRecordingIfNeeded()
        restored.restoreInterruptedRecordingIfNeeded()

        #expect(provider.sessionsCreated == 1)
        #expect(provider.liveUpdateStreamsCreated == 1)
    }

    @Test("With no marker there is nothing to restore")
    func nothingToRestore() throws {
        let harness = try RecordingHarness()
        harness.coordinator.restoreInterruptedRecordingIfNeeded()
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.provider.sessionsCreated == 0)
    }

    @Test("Restore is skipped entirely when the process must stay inert")
    func restoreCanBeDisabled() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        let inert = RecordingCoordinator(
            trackStore: harness.store,
            markerStore: harness.markerStore,
            provider: TestLocationUpdatesProvider(),
            allowsRestore: false
        )
        inert.restoreInterruptedRecordingIfNeeded()
        #expect(inert.phase == .idle)
    }

    @Test("A marker pointing at a missing session is abandoned, not invented")
    func abandonsMissingSession() async throws {
        let harness = try RecordingHarness()
        harness.markerStore.save(RecoveryMarker(sessionID: UUID(), startedAt: testBase))

        let provider = TestLocationUpdatesProvider()
        let coordinator = RecordingCoordinator(
            trackStore: harness.store,
            markerStore: harness.markerStore,
            provider: provider
        )
        coordinator.restoreInterruptedRecordingIfNeeded()

        try await waitUntil("abandoned") { coordinator.phase == .failed(.recoveredSessionMissing) }
        #expect(harness.markerStore.load() == nil)
        #expect(provider.sessionsOutstanding == 0)
    }

    @Test("A marker left behind by a completed stop is just cleaned up")
    func markerOutlivingCompletedStop() async throws {
        let harness = try RecordingHarness()
        let sessionID = UUID()
        try await harness.store.createSession(id: sessionID, name: "Soccer", startedAt: testBase)
        try await harness.store.endSession(id: sessionID, endedAt: testBase.addingTimeInterval(60))
        // The process died between writing the end time and clearing the marker.
        harness.markerStore.save(RecoveryMarker(sessionID: sessionID, startedAt: testBase))

        let provider = TestLocationUpdatesProvider()
        let coordinator = RecordingCoordinator(
            trackStore: harness.store,
            markerStore: harness.markerStore,
            provider: provider
        )
        coordinator.restoreInterruptedRecordingIfNeeded()

        try await waitUntil("cleaned up") { coordinator.phase == .idle }
        #expect(harness.markerStore.load() == nil)
        #expect(provider.sessionsOutstanding == 0)
        // The finished session keeps its data.
        #expect(try await harness.store.sessionSnapshot(id: sessionID)?.endedAt != nil)
    }

    // MARK: - Authorization and diagnostics

    @Test("Denied permission fails the recording and rolls back the empty session")
    func deniedPermission() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)

        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.authorizationDenied = true
        harness.provider.emit(diagnostic)

        try await waitUntil("denied") { harness.coordinator.phase == .failed(.permissionDenied) }
        #expect(harness.provider.sessionsOutstanding == 0)
        #expect(harness.markerStore.load() == nil)
        // Nothing was captured, so no empty session is left in the list.
        #expect(try await harness.store.sessionSnapshot(id: sessionID) == nil)
    }

    @Test("Location Services being off globally is reported as such")
    func locationServicesDisabled() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        var event = LocationUpdateEvent(sample: nil)
        event.authorizationDeniedGlobally = true
        harness.provider.emit(event)

        try await waitUntil("services off") {
            harness.coordinator.phase == .failed(.locationServicesDisabled)
        }
        #expect(RecordingProblem.locationServicesDisabled.title == "Location is off")
        #expect(RecordingProblem.locationServicesDisabled.suggestsSettings)
    }

    @Test("A recording that captured data is closed, not discarded, when it fails")
    func failureKeepsCapturedData() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.authorizationDenied = true
        harness.provider.emit(diagnostic)

        try await waitUntil("denied") { harness.coordinator.phase == .failed(.permissionDenied) }
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt != nil)
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
    }

    @Test("Reduced accuracy is shown but does not stop recording")
    func reducedAccuracyKeepsRecording() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.fullAccuracyDenied = true
        harness.provider.emit(diagnostic)

        try await waitUntil("reduced accuracy") { harness.coordinator.isPreciseLocationDenied }
        harness.deliver(sample(1, accuracy: 800))
        try await waitUntil("still recording") { harness.coordinator.phase == .tracking }

        #expect(harness.coordinator.recordedPointCount == 1)
        #expect(harness.provider.sessionsOutstanding == 1)
    }

    @Test("A limited background activity is surfaced without failing")
    func backgroundActivityLimited() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        var diagnostic = SessionDiagnostic(source: .backgroundActivitySession)
        diagnostic.insufficientlyInUse = true
        harness.provider.emit(diagnostic)

        try await waitUntil("limited") { harness.coordinator.isBackgroundActivityLimited }
        #expect(harness.coordinator.phase.isActive)
    }

    @Test("Dismissing a failure returns to idle")
    func dismissFailure() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        var event = LocationUpdateEvent(sample: nil)
        event.authorizationDenied = true
        harness.provider.emit(event)
        try await waitUntil("failed") { harness.coordinator.phase == .failed(.permissionDenied) }

        harness.coordinator.dismissFailure()
        #expect(harness.coordinator.phase == .idle)

        // And a new recording can begin.
        await harness.coordinator.startRecording()
        #expect(harness.coordinator.phase.isActive)
    }

    // MARK: - End to end

    @Test("A recovered session exports with its gap preserved")
    func exportFromRecoveredSession() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)

        harness.deliver(sample(0, positionA))
        harness.deliver(sample(10, positionA, stationary: true))
        try await waitUntil("two fixes") { harness.coordinator.recordedPointCount == 2 }

        // Process dies; a new coordinator rejoins and records after a twelve-minute gap.
        let provider = TestLocationUpdatesProvider()
        let clock = MutableClock(testBase.addingTimeInterval(720))
        let restored = RecordingCoordinator(
            trackStore: harness.store,
            markerStore: harness.markerStore,
            provider: provider,
            now: { clock.now }
        )
        restored.restoreInterruptedRecordingIfNeeded()
        try await waitUntil("rejoined") { restored.recordedPointCount == 2 }

        clock.now = testBase.addingTimeInterval(720)
        provider.emit(sample(720, positionB))
        try await waitUntil("third fix") { restored.recordedPointCount == 3 }
        clock.advance(60)
        await restored.stopRecording()

        let input = try await #require(harness.store.exportInput(sessionID: sessionID))
        let points = GPXExporter().plan(session: input.session, samples: input.samples)

        // The stationary bridge holds A across the gap rather than drifting to B.
        #expect(points.map(\.offsetFromBase) == [0, 10, 719, 720])
        #expect(points.map(\.origin) == [.observed, .observed, .stationaryBridge, .observed])
        let bridge = try #require(points.first { $0.origin == .stationaryBridge })
        #expect(bridge.latitude == positionA.latitude)
    }
}
