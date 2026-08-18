import Foundation
import Testing
@testable import GPeX

/// A real recording driven at each of the four cadences, and the neutral status vocabulary
/// that replaced "Moving".
///
/// Everything goes through `RecordingCoordinator` and the same event stream Core Location
/// would use, so these assertions are about what a device actually does rather than about
/// what the gate would decide in isolation.
@Suite("Recording cadence and neutral status")
@MainActor
struct RecordingCadenceTests {

    /// A position `meters` north of `positionA` — the wander a phone produces standing still.
    private func drifted(_ meters: Double) -> (latitude: Double, longitude: Double) {
        (latitude: positionA.latitude + meters / 111_320, longitude: positionA.longitude)
    }

    // MARK: - Neutral tracking

    @Test("An ordinary running recording is neutral tracking, and never claims movement")
    func ordinaryRecordingIsNeutralTracking() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        let phase = harness.coordinator.phase
        #expect(phase == .tracking)
        #expect(phase.isActive)
        #expect(phase.headline == "Recording")
        #expect(phase.activityTitle == "Tracking location")
        // Nothing to apologise for or explain: it is simply recording.
        #expect(phase.activityDetail == nil)
    }

    /// The whole point of the change: GPeX cannot see whether anyone is walking, so it
    /// must not say so anywhere a person can read it.
    @Test("No user-facing recording copy says Moving")
    func noCopySaysMoving() {
        let phases: [RecordingPhase] = [
            .idle, .waitingForAuthorization, .acquiringLocation, .tracking, .stationary,
            .temporarilyUnavailable, .stopping, .failed(.permissionDenied),
            .failed(.locationServicesDisabled), .failed(.storageFailure("disk full")),
        ]
        for phase in phases {
            let copy = [phase.headline, phase.statusTitle, phase.activityTitle ?? "",
                        phase.activityDetail ?? ""].joined(separator: " ")
            #expect(!copy.localizedCaseInsensitiveContains("moving"), "\(phase) says \(copy)")
        }

        // And the Lock Screen projection of every one of them.
        for status in RecordingLiveStatus.allCases {
            let copy = "\(status.title) \(status.detail ?? "")"
            #expect(!copy.localizedCaseInsensitiveContains("moving"), "\(status) says \(copy)")
            // No walking figure either — a symbol is a claim as much as a word is.
            #expect(status.symbolName != "figure.walk")
        }

        // Including the state label reported to the system.
        #expect(RecordingPhase.tracking.performanceStateLabel == "tracking")
    }

    // MARK: - Stationary is explicit only

    @Test("Stationary is entered only when Core Location explicitly reports it")
    func stationaryRequiresAnExplicitReport() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()

        // Fixes with no stationary flag, however slow, still, or close together, are
        // ordinary tracking. GPeX runs no speed threshold of its own.
        harness.deliver(sample(1, positionA, speed: 0))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }
        harness.deliver(sample(40, drifted(0.5), speed: 0))
        try await waitUntil("two fixes") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.phase == .tracking)

        // Only the explicit flag changes it.
        harness.deliver(sample(45, drifted(0.5), stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }
        #expect(harness.coordinator.phase.activityTitle == "Stationary")
        #expect(harness.coordinator.phase.activityDetail == "Saving battery")
    }

    @Test("Resuming after stationary returns to neutral tracking, not to Moving")
    func resumingReturnsToNeutralTracking() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        harness.deliver(sample(2, positionA, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        // Core Location starts delivering again. GPeX says only that it is tracking.
        harness.deliver(sample(600, positionB))
        try await waitUntil("tracking again") { harness.coordinator.phase == .tracking }
        #expect(harness.coordinator.phase.activityTitle == "Tracking location")

        // And it resumed by itself: no new stream, no new sessions, nothing restarted.
        #expect(harness.provider.liveUpdateStreamsCreated == 1)
        #expect(harness.provider.sessionsCreated == 1)
        #expect(harness.provider.sessionsOutstanding == 1)
    }

    @Test("A location-less stationary report also resumes into neutral tracking")
    func resumingFromLocationlessStationary() async throws {
        let harness = try RecordingHarness()
        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.provider.emitStationaryWithoutLocation()
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        // Well inside the interval and barely moved, but it is the first fix after a
        // stationary stretch, so it is both saved and reported as tracking.
        harness.deliver(sample(4, drifted(1)))
        try await waitUntil("tracking again") { harness.coordinator.phase == .tracking }
        try await waitUntil("resumed fix saved") { harness.coordinator.recordedPointCount == 2 }
    }

    // MARK: - The four cadences, end to end

    @Test("Each interval keeps the first fix and coalesces until it elapses",
          arguments: LocationSaveInterval.allCases)
    func everyIntervalCoalescesUntilItElapses(_ interval: LocationSaveInterval) async throws {
        let harness = try RecordingHarness(saveInterval: interval)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()
        #expect(harness.coordinator.saveInterval == interval)

        // The first fix is never held back, whatever the cadence.
        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // One second short of the interval, a metre away: nothing new to say.
        harness.deliver(sample(interval.seconds - 1, drifted(1)))
        // On the interval: saved.
        harness.deliver(sample(interval.seconds, drifted(1)))
        try await waitUntil("second fix") { harness.coordinator.recordedPointCount == 2 }

        // Exactly two rows, and they are the two expected ones — which is what proves the
        // middle fix was coalesced rather than merely arriving late.
        #expect(harness.coordinator.recordedPointCount == 2)
        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.map { $0.timestamp.timeIntervalSince(testBase) } == [0, interval.seconds])
    }

    @Test("Thirty seconds is what a recording uses when nobody has chosen anything")
    func defaultsToThirtySeconds() async throws {
        // No preference has ever been written in this harness's defaults domain.
        let harness = try RecordingHarness()
        #expect(harness.coordinator.preferredSaveInterval == .thirtySeconds)

        await harness.coordinator.startRecording()
        #expect(harness.coordinator.saveInterval == .thirtySeconds)
        #expect(try #require(harness.saveGate).interval == .thirtySeconds)
    }

    @Test("A chosen interval is remembered for the next launch")
    func intervalIsRemembered() throws {
        let harness = try RecordingHarness()
        harness.coordinator.setPreferredSaveInterval(.oneMinute)
        #expect(harness.coordinator.preferredSaveInterval == .oneMinute)

        // A fresh preferences object over the same defaults, as after a relaunch.
        let reloaded = RecordingPreferences(defaults: harness.defaults)
        #expect(reloaded.saveInterval == .oneMinute)
        #expect(harness.defaults.integer(forKey: RecordingPreferences.saveIntervalKey) == 60)
    }

    @Test("Changing the preference does not disturb a recording already running")
    func runningRecordingKeepsItsCadence() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()
        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.coordinator.setPreferredSaveInterval(.tenSeconds)

        // The preference changed; this recording did not.
        #expect(harness.coordinator.preferredSaveInterval == .tenSeconds)
        #expect(harness.coordinator.saveInterval == .oneMinute)

        // Still coalescing at a minute, as it started.
        harness.deliver(sample(15, drifted(1)))
        harness.deliver(sample(60, drifted(1)))
        try await waitUntil("second fix") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.recordedPointCount == 2)

        // And the next recording picks up the new choice.
        await harness.coordinator.stopRecording()
        await harness.coordinator.startRecording()
        #expect(harness.coordinator.saveInterval == .tenSeconds)
    }

    // MARK: - Jitter

    @Test("A burst of jittery fixes in one place becomes one row")
    func jitterIsCoalescedIntoOneRow() async throws {
        let harness = try RecordingHarness(saveInterval: .thirtySeconds)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()

        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // Ten deliveries over nine seconds, wandering a metre or two — a phone on a
        // tripod, not a photographer walking.
        for second in 1...9 {
            harness.deliver(sample(TimeInterval(second), drifted(Double(second % 3) + 0.5)))
        }
        // The interval finally elapses, which is the observable event to wait on.
        harness.deliver(sample(30, drifted(1)))
        try await waitUntil("second fix") { harness.coordinator.recordedPointCount == 2 }

        #expect(harness.coordinator.recordedPointCount == 2)
        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.map { $0.timestamp.timeIntervalSince(testBase) } == [0, 30])
    }

    // MARK: - Overrides

    @Test("Real movement is saved without waiting out the interval")
    func meaningfulMovementIsSavedEarly() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()

        harness.deliver(sample(0, positionA, accuracy: 8))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // 55 m in three seconds, with both fixes claiming ±8 m: a real walk down the line.
        harness.deliver(sample(3, positionB, accuracy: 8))
        try await waitUntil("movement saved") { harness.coordinator.recordedPointCount == 2 }

        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.map { $0.timestamp.timeIntervalSince(testBase) } == [0, 3])
    }

    @Test("The same displacement between coarse fixes is coalesced instead")
    func coarseDisplacementIsNotTreatedAsMovement() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()

        harness.deliver(sample(0, positionA, accuracy: 50))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // 55 m between two ±50 m fixes is inside the noise, so the interval governs.
        harness.deliver(sample(3, positionB, accuracy: 50))
        harness.deliver(sample(60, positionB, accuracy: 50))
        try await waitUntil("interval fix") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.recordedPointCount == 2)
    }

    @Test("A materially better fix is saved without waiting out the interval")
    func improvedAccuracyIsSavedEarly() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()

        // A first fix while the radio is still settling.
        harness.deliver(sample(0, positionA, accuracy: 60))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // Same place, but GPS has locked on. Worth a row: every geotagged photo is asking
        // where the photographer was, and this is a much better answer.
        harness.deliver(sample(4, drifted(1), accuracy: 8))
        try await waitUntil("better fix saved") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.latestSample?.horizontalAccuracy == 8)
    }

    @Test("Becoming stationary is recorded without waiting out the interval")
    func stationaryIsSavedEarly() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()

        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.deliver(sample(5, drifted(1), stationary: true))
        try await waitUntil("stationary saved") { harness.coordinator.recordedPointCount == 2 }
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.last?.stationary == true)
    }

    @Test("A long stationary stretch does not fill the track with one square metre")
    func stationaryStretchStillObeysTheInterval() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()

        harness.deliver(sample(0, positionA, stationary: true))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        // Nine more stationary reports over half a minute, all in the same spot.
        for second in stride(from: 3, through: 30, by: 3) {
            harness.deliver(sample(TimeInterval(second), drifted(1), stationary: true))
        }
        harness.deliver(sample(60, drifted(1), stationary: true))
        try await waitUntil("interval fix") { harness.coordinator.recordedPointCount == 2 }
        #expect(harness.coordinator.recordedPointCount == 2)
    }

    // MARK: - Recovery

    @Test("An interrupted recording resumes at the interval it was running at")
    func recoveryPreservesTheInterval() async throws {
        let first = try RecordingHarness(saveInterval: .tenSeconds)
        await first.coordinator.startRecording()
        let sessionID = try first.activeSessionID()
        first.deliver(sample(0))
        try await waitUntil("first fix") { first.coordinator.recordedPointCount == 1 }

        let marker = try #require(first.markerStore.load())
        #expect(marker.saveInterval == .tenSeconds)

        // Relaunch. The fresh preferences object has never been written to, so it would
        // say thirty seconds — the marker is what keeps the session honest.
        let provider = TestLocationUpdatesProvider()
        let clock = MutableClock(testBase.addingTimeInterval(300))
        let restored = RecordingCoordinator(
            trackStore: first.store,
            markerStore: first.markerStore,
            provider: provider,
            preferences: RecordingPreferences(defaults: UserDefaults(suiteName: "GPeXTests.\(UUID().uuidString)")!),
            now: { clock.now }
        )
        restored.restoreInterruptedRecordingIfNeeded()

        #expect(restored.saveInterval == .tenSeconds)
        #expect(restored.preferredSaveInterval == .thirtySeconds)
        try await waitUntil("rejoined") { restored.recordedPointCount == 1 }

        // The first fix after a relaunch is always kept, gap or no gap: the rejoined
        // recording has nothing saved of its own to coalesce against.
        clock.now = testBase.addingTimeInterval(309)
        provider.emit(sample(309, drifted(1)))
        try await waitUntil("resumed fix") { restored.recordedPointCount == 2 }

        // And from there it really is running at ten seconds: 6 s coalesced, 10 s kept.
        clock.now = testBase.addingTimeInterval(315)
        provider.emit(sample(315, drifted(1)))
        clock.now = testBase.addingTimeInterval(319)
        provider.emit(sample(319, drifted(1)))
        try await waitUntil("third fix") { restored.recordedPointCount == 3 }

        let samples = try await first.store.samples(sessionID: sessionID)
        #expect(samples.map { $0.timestamp.timeIntervalSince(testBase) } == [0, 309, 319])
        #expect(provider.liveUpdateStreamsCreated == 1)
    }

    @Test("A recovery marker written before the setting existed resumes at thirty seconds")
    func legacyMarkerDefaultsToThirtySeconds() async throws {
        let harness = try RecordingHarness()
        let sessionID = UUID()
        try await harness.store.createSession(id: sessionID, name: "Soccer", startedAt: testBase)

        // Exactly what an older build wrote: the three original keys and nothing else.
        harness.defaults.set(sessionID.uuidString, forKey: RecoveryMarkerStore.sessionIDKey)
        harness.defaults.set(testBase, forKey: RecoveryMarkerStore.startedAtKey)
        harness.defaults.set(true, forKey: RecoveryMarkerStore.recordingRequestedKey)

        // The marker is honoured rather than discarded, and fills in the default cadence.
        let marker = try #require(harness.markerStore.load())
        #expect(marker.sessionID == sessionID)
        #expect(marker.startedAt == testBase)
        #expect(marker.saveInterval == .thirtySeconds)

        let provider = TestLocationUpdatesProvider()
        let clock = MutableClock(testBase.addingTimeInterval(120))
        let restored = RecordingCoordinator(
            trackStore: harness.store,
            markerStore: harness.markerStore,
            provider: provider,
            now: { clock.now }
        )
        restored.restoreInterruptedRecordingIfNeeded()

        #expect(restored.saveInterval == .thirtySeconds)
        try await waitUntil("rejoined") { restored.phase.isActive }
        #expect(provider.liveUpdateStreamsCreated == 1)
    }

    @Test("A cleared marker leaves no interval behind for the next recording to inherit")
    func stoppingClearsTheStoredInterval() async throws {
        let harness = try RecordingHarness(saveInterval: .tenSeconds)
        await harness.coordinator.startRecording()
        #expect(harness.defaults.integer(forKey: RecoveryMarkerStore.saveIntervalKey) == 10)

        await harness.coordinator.stopRecording()

        #expect(harness.markerStore.load() == nil)
        #expect(harness.defaults.object(forKey: RecoveryMarkerStore.saveIntervalKey) == nil)
        // The *preference* survives the stop; only the marker is transient.
        #expect(harness.coordinator.preferredSaveInterval == .tenSeconds)
    }

    // MARK: - Stopping

    @Test("Stopping mid-interval closes the session and keeps what was saved")
    func stoppingWithACoalescedFixPending() async throws {
        let harness = try RecordingHarness(saveInterval: .oneMinute)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()

        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }
        // Coalesced, and never revived by the stop: a suppressed fix is not a buffer.
        harness.deliver(sample(5, drifted(1)))

        harness.clock.advance(600)
        await harness.coordinator.stopRecording()

        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.lastFinishedSessionID == sessionID)
        #expect(harness.provider.sessionsOutstanding == 0)
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt == harness.clock.now)
    }

    @Test("Nothing is saved after a stop, whatever the interval says")
    func noSavesAfterStop() async throws {
        let harness = try RecordingHarness(saveInterval: .tenSeconds)
        await harness.coordinator.startRecording()
        let sessionID = try harness.activeSessionID()
        harness.deliver(sample(0))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        await harness.coordinator.stopRecording()

        // Well past the interval, and real movement besides: still nothing.
        harness.deliver(sample(60, positionB))
        harness.deliver(sample(120, positionC))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
    }

    // MARK: - One stream, always

    /// The invariant the whole design rests on. An interval that reached Core Location, or
    /// any manual stop-and-start to "apply" a new cadence, would show up here.
    @Test("One recording has exactly one live-update stream, whatever happens to it")
    func exactlyOneStreamPerRecording() async throws {
        let harness = try RecordingHarness(saveInterval: .tenSeconds)

        await harness.coordinator.startRecording()
        // Second and third taps, a restore attempt, and a preference change mid-recording.
        await harness.coordinator.startRecording()
        harness.coordinator.restoreInterruptedRecordingIfNeeded()
        harness.coordinator.setPreferredSaveInterval(.oneMinute)
        harness.coordinator.setPreferredSaveInterval(.tenSeconds)

        // A full cycle of tracking, stationary, resumed tracking and unavailable.
        harness.deliver(sample(0))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }
        harness.deliver(sample(20, positionA, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }
        harness.provider.emitStationaryWithoutLocation()
        harness.deliver(sample(400, positionB))
        try await waitUntil("tracking again") { harness.coordinator.phase == .tracking }

        var unavailable = LocationUpdateEvent(sample: nil)
        unavailable.locationUnavailable = true
        harness.provider.emit(unavailable)
        try await waitUntil("unavailable") { harness.coordinator.phase == .temporarilyUnavailable }

        #expect(harness.provider.liveUpdateStreamsCreated == 1)
        #expect(harness.provider.sessionsCreated == 1)
        #expect(harness.provider.sessionsOutstanding == 1)

        await harness.coordinator.stopRecording()
        #expect(harness.provider.liveUpdateStreamsCreated == 1)
        #expect(harness.provider.sessionsOutstanding == 0)

        // A second recording is a second stream, and still only one at a time.
        await harness.coordinator.startRecording()
        #expect(harness.provider.liveUpdateStreamsCreated == 2)
        #expect(harness.provider.sessionsOutstanding == 1)
    }
}
