import Foundation
import Testing
@testable import GPeX

/// The translation from recording state to Live Activity content.
///
/// This is the part worth testing hard: it is pure, it is where the user-visible wording
/// is decided, and it is the only thing standing between the recording engine and a
/// system surface anyone can read off a locked phone.
@Suite("Live Activity content")
@MainActor
struct RecordingLiveContentTests {

    /// One row of the mapping the Lock Screen is required to produce.
    nonisolated struct PhaseExpectation: Sendable {
        let phase: RecordingPhase
        let status: RecordingLiveStatus
        let label: String
    }

    nonisolated static let mappings: [PhaseExpectation] = [
        .init(phase: .waitingForAuthorization,
              status: .waitingForAuthorization,
              label: "Waiting for Location Access"),
        .init(phase: .acquiringLocation,
              status: .acquiringLocation,
              label: "Acquiring Location"),
        .init(phase: .tracking, status: .tracking, label: "Recording"),
        .init(phase: .stationary, status: .stationary, label: "Stationary"),
        .init(phase: .temporarilyUnavailable,
              status: .temporarilyUnavailable,
              label: "Location Temporarily Unavailable"),
        .init(phase: .stopping, status: .stopping, label: "Finishing Recording"),
    ]

    @Test("Every recording phase maps to its own Live Activity label", arguments: mappings)
    func phaseMapsToLabel(_ expectation: PhaseExpectation) throws {
        let snapshot = RecordingLiveSnapshot.fixture(phase: expectation.phase)
        let state = try #require(snapshot.contentState)
        #expect(state.status == expectation.status)
        #expect(state.status.title == expectation.label)
    }

    @Test("Every status is reachable from some phase, so none is dead wording")
    func everyStatusIsReachable() {
        let reachable = Set(Self.mappings.map(\.status))
        #expect(reachable == Set(RecordingLiveStatus.allCases))
    }

    @Test("Stationary says the recording is saving battery, never that it is paused")
    func stationaryIsNotPaused() throws {
        let state = try #require(RecordingLiveSnapshot.fixture(phase: .stationary).contentState)
        #expect(state.status.title == "Stationary")
        #expect(state.status.detail == "Saving battery")
        for status in RecordingLiveStatus.allCases {
            #expect(!status.title.localizedCaseInsensitiveContains("pause"))
            #expect(!(status.detail ?? "").localizedCaseInsensitiveContains("pause"))
        }
    }

    @Test("No phase leaks Core Location vocabulary to the Lock Screen")
    func noFrameworkVocabulary() {
        let forbidden = ["CLLocation", "CLService", "authorization", "accuracyLimited",
                         "liveUpdates", "insufficientlyInUse", "nil", "CLBackground"]
        for status in RecordingLiveStatus.allCases {
            let text = "\(status.title) \(status.detail ?? "")"
            for word in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(status) says \(text)")
            }
        }
    }

    @Test("Idle and failed recordings have no Live Activity content at all")
    func inactivePhasesProduceNothing() {
        #expect(RecordingLiveSnapshot.fixture(phase: .idle).contentState == nil)
        #expect(RecordingLiveSnapshot.fixture(phase: .failed(.permissionDenied)).contentState == nil)
        #expect(RecordingLiveSnapshot.fixture(phase: .failed(.locationServicesDisabled)).contentState == nil)
    }

    // MARK: - Point count

    @Test("The persisted point count is carried through untouched")
    func carriesPointCount() throws {
        for count in [0, 1, 38, 4_211] {
            let state = try #require(RecordingLiveSnapshot.fixture(pointCount: count).contentState)
            #expect(state.pointCount == count)
        }
    }

    @Test("The count reads correctly in the singular and the plural")
    func pluralisesCount() {
        #expect(RecordingText.locations(1) == "1 location")
        #expect(RecordingText.locations(0) == "0 locations")
        #expect(RecordingText.locations(38) == "38 locations")
        #expect(RecordingText.locationsRecorded(1) == "1 location recorded")
        #expect(RecordingText.locationsRecorded(38) == "38 locations recorded")
    }

    // MARK: - Accuracy

    /// The rendered string is localised — `±7 m` metric, `±23 ft` in a US locale — so the
    /// assertion is against the app's own formatter rather than a literal.
    @Test("Accuracy is included when a current fix describes one")
    func accuracyIncluded() throws {
        for phase in [RecordingPhase.tracking, .stationary] {
            let state = try #require(
                RecordingLiveSnapshot.fixture(phase: phase, horizontalAccuracy: 7).contentState
            )
            #expect(state.horizontalAccuracy == 7)
            #expect(state.accuracyText == Formatters.accuracy(7))
            #expect(state.accuracyText?.hasPrefix("±") == true)
        }
    }

    @Test("Accuracy is omitted when there is none")
    func accuracyOmittedWhenAbsent() throws {
        let state = try #require(
            RecordingLiveSnapshot.fixture(horizontalAccuracy: nil).contentState
        )
        #expect(state.horizontalAccuracy == nil)
        #expect(state.accuracyText == nil)
        #expect(state.spokenAccuracy == nil)
    }

    /// A radius from the last fix does not describe where the device is now, so it is
    /// dropped rather than shown stale.
    @Test("Accuracy is dropped while no fix is current, even if a value exists")
    func accuracyDroppedWhenNotCurrent() throws {
        for phase in [RecordingPhase.acquiringLocation, .temporarilyUnavailable,
                      .waitingForAuthorization, .stopping] {
            let state = try #require(
                RecordingLiveSnapshot.fixture(phase: phase, horizontalAccuracy: 7).contentState
            )
            #expect(state.horizontalAccuracy == nil, "\(phase) kept a stale accuracy")
            #expect(state.accuracyText == nil)
        }
    }

    @Test("Accuracy formatting is shared with the app, not reimplemented")
    func accuracyMatchesTheApp() {
        for meters in [0.0, 4.4, 7.0, 65.0, 800.0] {
            #expect(RecordingText.accuracy(meters) == Formatters.accuracy(meters))
        }
    }

    @Test("Accuracy is spelled out for VoiceOver rather than left as a plus-minus sign")
    func spokenAccuracyIsSpelledOut() throws {
        let state = try #require(RecordingLiveSnapshot.fixture(horizontalAccuracy: 7).contentState)
        let spoken = try #require(state.spokenAccuracy)
        #expect(!spoken.contains("±"))
        #expect(spoken.localizedCaseInsensitiveContains("accuracy"))
    }

    // MARK: - Reduced accuracy

    @Test("Reduced accuracy is carried as its own flag and does not stop the recording")
    func reducedAccuracyIsItsOwnFlag() throws {
        let on = try #require(
            RecordingLiveSnapshot.fixture(phase: .tracking, reducedAccuracy: true).contentState
        )
        #expect(on.reducedAccuracy)
        // Still a normal, running recording — it just says the positions are coarser.
        #expect(on.status == .tracking)

        let off = try #require(RecordingLiveSnapshot.fixture(reducedAccuracy: false).contentState)
        #expect(!off.reducedAccuracy)
    }

    @Test("Reduced accuracy is announced in words and a symbol, not by colour")
    func reducedAccuracyIsNotColourOnly() {
        #expect(RecordingText.reducedAccuracyTitle == "Reduced Accuracy")
        #expect(!RecordingText.reducedAccuracySymbol.isEmpty)
    }

    // MARK: - Privacy

    /// The Live Activity is readable by anyone holding the locked phone, so what is *not*
    /// in the payload matters as much as what is.
    @Test("No coordinate can reach ActivityKit, because the content state has nowhere to put one")
    func contentStateCarriesNoCoordinates() throws {
        let state = try #require(RecordingLiveSnapshot.fixture().contentState)
        let encoded = try JSONEncoder().encode(state)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let json = try #require(object as? [String: Any])
        #expect(Set(json.keys) == ["status", "horizontalAccuracy", "pointCount", "reducedAccuracy"])
        for banned in ["latitude", "longitude", "altitude", "speed", "course", "coordinate"] {
            #expect(json[banned] == nil)
        }
    }

    @Test("No elapsed duration is sent through ActivityKit; the system renders it")
    func noElapsedSecondsInContent() throws {
        // Two snapshots of the same recording taken an hour apart must be identical
        // content: the timer is drawn from the static start date, not pushed.
        let sessionID = UUID()
        let early = RecordingLiveSnapshot.fixture(sessionID: sessionID, startedAt: testBase)
        let late = RecordingLiveSnapshot.fixture(sessionID: sessionID, startedAt: testBase)
        let earlyState = try #require(early.contentState)
        let lateState = try #require(late.contentState)
        #expect(earlyState == lateState)
        // And the start date lives in the static attributes, which never change.
        #expect(early.attributes.startedAt == testBase)
        #expect(early.attributes.sessionID == sessionID)
    }

    @Test("The content state survives a round trip through ActivityKit's coding")
    func contentStateRoundTrips() throws {
        for phase in Self.mappings.map(\.phase) {
            let original = try #require(
                RecordingLiveSnapshot.fixture(
                    phase: phase,
                    horizontalAccuracy: 12,
                    pointCount: 9,
                    reducedAccuracy: true
                ).contentState
            )
            let decoded = try JSONDecoder().decode(
                RecordingActivityAttributes.ContentState.self,
                from: try JSONEncoder().encode(original)
            )
            #expect(decoded == original)
        }
    }

    // MARK: - Deep link

    @Test("The Live Activity's deep link is recognised, and nothing else is")
    func deepLinkMatching() throws {
        let url = try #require(RecordingDeepLink.activeRecording)
        #expect(url.absoluteString == "gpex://recording")
        #expect(RecordingDeepLink.isActiveRecording(url))
        #expect(!RecordingDeepLink.isActiveRecording(try #require(URL(string: "gpex://settings"))))
        #expect(!RecordingDeepLink.isActiveRecording(try #require(URL(string: "https://recording"))))
    }
}

// MARK: - Manager

@Suite("Live Activity manager")
@MainActor
struct RecordingLiveActivityManagerTests {

    private func makeManager() -> (RecordingLiveActivityManager, FakeActivityHost) {
        let host = FakeActivityHost()
        return (RecordingLiveActivityManager(host: host), host)
    }

    // MARK: - Starting

    @Test("Starting a recording requests exactly one activity, carrying the session id")
    func startRequestsOneActivity() throws {
        let (manager, host) = makeManager()
        let snapshot = RecordingLiveSnapshot.fixture(phase: .waitingForAuthorization)

        manager.start(snapshot)

        #expect(host.requested.count == 1)
        #expect(host.requested[0].sessionID == snapshot.sessionID)
        #expect(host.requested[0].startedAt == snapshot.startedAt)
        let handle = try #require(host.created.first)
        #expect(handle.latestState?.status == .waitingForAuthorization)
    }

    @Test("One recording cannot own two Live Activities")
    func oneRecordingOneActivity() async {
        let (manager, host) = makeManager()
        let snapshot = RecordingLiveSnapshot.fixture()

        manager.start(snapshot)
        manager.start(snapshot)
        manager.start(snapshot)
        // Reconciling mid-recording must not conjure a second one either.
        manager.reconcile(with: snapshot, creatingIfMissing: true)
        await manager.flushPendingWork()

        #expect(host.requested.count == 1)
        #expect(host.created.count == 1)
    }

    @Test("A leftover activity from an earlier session is ended when a new one starts")
    func startEndsLeftovers() async {
        let (manager, host) = makeManager()
        let leftover = FakeActivityHandle(sessionID: UUID())
        host.preexisting = [leftover]

        manager.start(.fixture())
        await manager.flushPendingWork()

        #expect(leftover.isEnded)
        #expect(host.requested.count == 1)
    }

    @Test("With Live Activities turned off, nothing is requested and nothing throws")
    func disabledActivitiesAreSkipped() async {
        let (manager, host) = makeManager()
        host.areActivitiesEnabled = false

        manager.start(.fixture())
        manager.update(.fixture())
        await manager.end()

        #expect(host.requested.isEmpty)
    }

    @Test("A refusal from ActivityKit is logged and dropped, leaving the manager idle")
    func requestFailureIsAbsorbed() async {
        let (manager, host) = makeManager()
        host.requestError = ActivityKitRefused()

        manager.start(.fixture())
        manager.update(.fixture(pointCount: 99))
        // And ending afterwards is still safe.
        await manager.end()

        #expect(host.created.isEmpty)
    }

    // MARK: - Updating

    @Test("Content identical to the last one sent is not sent again")
    func duplicateStatesAreNotResent() async throws {
        let (manager, host) = makeManager()
        let snapshot = RecordingLiveSnapshot.fixture(phase: .stationary)
        manager.start(snapshot)
        let handle = try #require(host.created.first)
        let afterStart = handle.states.count

        manager.update(snapshot)
        manager.update(snapshot)
        manager.update(snapshot)
        await manager.flushPendingWork()

        #expect(handle.states.count == afterStart)
    }

    /// A snapshot that differs only in something the Live Activity does not show is
    /// still a duplicate as far as ActivityKit is concerned.
    @Test("A change the Lock Screen would not show is also not sent")
    func invisibleChangesAreNotResent() async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        manager.start(.fixture(sessionID: sessionID, phase: .acquiringLocation, horizontalAccuracy: nil))
        let handle = try #require(host.created.first)
        let afterStart = handle.states.count

        // Acquiring does not display an accuracy, so acquiring one changes nothing yet.
        manager.update(.fixture(sessionID: sessionID, phase: .acquiringLocation, horizontalAccuracy: 30))
        await manager.flushPendingWork()

        #expect(handle.states.count == afterStart)
    }

    @Test("Each meaningful change is sent exactly once", arguments: [
        RecordingLiveSnapshot.Change.status,
        .accuracy,
        .pointCount,
        .reducedAccuracy,
    ])
    func meaningfulChangesAreSent(_ change: RecordingLiveSnapshot.Change) async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        let before = RecordingLiveSnapshot.fixture(
            sessionID: sessionID,
            phase: .tracking,
            horizontalAccuracy: 7,
            pointCount: 38,
            reducedAccuracy: false
        )
        manager.start(before)
        let handle = try #require(host.created.first)
        let afterStart = handle.states.count

        let after = before.applying(change)
        manager.update(after)
        manager.update(after)
        await manager.flushPendingWork()

        #expect(handle.states.count == afterStart + 1, "\(change) was not sent exactly once")
        #expect(handle.latestState == after.contentState)
    }

    @Test("An update for a different recording is ignored")
    func updatesForOtherRecordingsAreIgnored() async throws {
        let (manager, host) = makeManager()
        manager.start(.fixture(sessionID: UUID(), pointCount: 1))
        let handle = try #require(host.created.first)
        let afterStart = handle.states.count

        manager.update(.fixture(sessionID: UUID(), pointCount: 500))
        await manager.flushPendingWork()

        #expect(handle.states.count == afterStart)
    }

    @Test("Updates arrive in the order they were decided")
    func updatesAreOrdered() async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        manager.start(.fixture(sessionID: sessionID, pointCount: 0))
        let handle = try #require(host.created.first)

        for count in 1...5 {
            manager.update(.fixture(sessionID: sessionID, pointCount: count))
        }
        await manager.flushPendingWork()

        #expect(handle.states.map(\.pointCount) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Reconciling

    @Test("Recovery adopts the activity whose session id matches, not the first one")
    func reconcileMatchesBySessionID() async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        let wrongFirst = FakeActivityHandle(sessionID: UUID())
        let match = FakeActivityHandle(sessionID: sessionID)
        let wrongLast = FakeActivityHandle(sessionID: UUID())
        host.preexisting = [wrongFirst, match, wrongLast]

        manager.reconcile(
            with: .fixture(sessionID: sessionID, phase: .stationary, pointCount: 12),
            creatingIfMissing: false
        )
        await manager.flushPendingWork()

        // The matching activity was adopted and brought up to date...
        #expect(!match.isEnded)
        #expect(match.latestState?.status == .stationary)
        #expect(match.latestState?.pointCount == 12)
        // ...the others were cleaned up, and no duplicate was created.
        #expect(wrongFirst.isEnded)
        #expect(wrongLast.isEnded)
        #expect(host.requested.isEmpty)
    }

    @Test("An adopted activity is then updated like any other")
    func adoptedActivityKeepsUpdating() async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        let match = FakeActivityHandle(sessionID: sessionID)
        host.preexisting = [match]

        manager.reconcile(with: .fixture(sessionID: sessionID, pointCount: 2), creatingIfMissing: false)
        manager.update(.fixture(sessionID: sessionID, pointCount: 3))
        await manager.flushPendingWork()

        #expect(match.states.map(\.pointCount) == [2, 3])
        #expect(host.requested.isEmpty)
    }

    /// A background relaunch by Core Location must not depend on ActivityKit at all.
    @Test("With no activity to rejoin, recovery creates nothing unless asked to")
    func reconcileWithoutMatchCreatesNothing() async {
        let (manager, host) = makeManager()

        manager.reconcile(with: .fixture(), creatingIfMissing: false)
        await manager.flushPendingWork()

        #expect(host.requested.isEmpty)
    }

    @Test("Coming back to the foreground may recreate a missing activity")
    func reconcileMayRecreate() async throws {
        let (manager, host) = makeManager()
        let snapshot = RecordingLiveSnapshot.fixture(phase: .stationary, pointCount: 41)

        manager.reconcile(with: snapshot, creatingIfMissing: true)
        await manager.flushPendingWork()

        #expect(host.requested.count == 1)
        #expect(host.requested[0].sessionID == snapshot.sessionID)
        #expect(try #require(host.created.first).latestState?.pointCount == 41)
    }

    @Test("Reconciling against an unrelated recording changes nothing")
    func reconcileRejectsAnotherRecording() async {
        let (manager, host) = makeManager()
        manager.start(.fixture())

        manager.reconcile(with: .fixture(sessionID: UUID()), creatingIfMissing: true)
        await manager.flushPendingWork()

        #expect(host.requested.count == 1)
    }

    // MARK: - Ending

    @Test("Ending is idempotent")
    func endIsIdempotent() async throws {
        let (manager, host) = makeManager()
        manager.start(.fixture())
        let handle = try #require(host.created.first)

        await manager.end()
        await manager.end()
        await manager.end()

        #expect(handle.endCount == 1)
    }

    @Test("Ending when there was never an activity is a no-op, not a failure")
    func endWithoutActivity() async {
        let (manager, host) = makeManager()
        await manager.end()
        await manager.end()
        #expect(host.created.isEmpty)
    }

    @Test("After ending, a later update cannot resurrect the activity")
    func updateAfterEndDoesNothing() async throws {
        let (manager, host) = makeManager()
        let snapshot = RecordingLiveSnapshot.fixture()
        manager.start(snapshot)
        let handle = try #require(host.created.first)
        await manager.end()
        let statesAtEnd = handle.states.count

        manager.update(.fixture(sessionID: snapshot.sessionID, pointCount: 999))
        await manager.flushPendingWork()

        #expect(handle.states.count == statesAtEnd)
        #expect(host.requested.count == 1)
    }

    @Test("Ending waits for the updates already decided, so none is lost or reordered")
    func endFlushesQueuedUpdates() async throws {
        let (manager, host) = makeManager()
        let sessionID = UUID()
        manager.start(.fixture(sessionID: sessionID, phase: .tracking, pointCount: 1))
        let handle = try #require(host.created.first)

        manager.update(.fixture(sessionID: sessionID, phase: .stopping, pointCount: 1))
        await manager.end()

        #expect(handle.states.last?.status == .stopping)
        #expect(handle.endCount == 1)
    }
}

// MARK: - Coordinator integration

@Suite("Live Activity does not affect recording")
@MainActor
struct RecordingLiveActivityIntegrationTests {

    private func makeHarness() throws -> (RecordingHarness, FakeActivityHost, RecordingLiveActivityManager) {
        let host = FakeActivityHost()
        let manager = RecordingLiveActivityManager(host: host)
        return (try RecordingHarness(liveActivity: manager), host, manager)
    }

    @Test("Starting a recording starts one Live Activity for that recording")
    func startCreatesOneActivity() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)

        #expect(host.requested.count == 1)
        #expect(host.requested[0].sessionID == sessionID)
        #expect(host.requested[0].startedAt == harness.clock.now)
    }

    @Test("Two taps on Start still leave one Live Activity")
    func doubleStartCreatesOneActivity() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        await harness.coordinator.startRecording()
        #expect(host.requested.count == 1)
    }

    @Test("Accepted fixes move the activity through acquiring, tracking and stationary")
    func activityFollowsRecordingState() async throws {
        let (harness, host, manager) = try makeHarness()
        await harness.coordinator.startRecording()
        let handle = try #require(host.created.first)

        harness.provider.emit(SessionDiagnostic(source: .serviceSession))
        try await waitUntil("acquiring") { harness.coordinator.phase == .acquiringLocation }

        harness.deliver(sample(1, accuracy: 6))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        harness.deliver(sample(2, accuracy: 9, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }
        await manager.flushPendingWork()

        let statuses = handle.states.map(\.status)
        #expect(statuses.first == .waitingForAuthorization)
        #expect(statuses.last == .stationary)
        #expect(statuses.contains(.acquiringLocation))
        #expect(statuses.contains(.tracking))

        // The count and accuracy shown are the recording engine's, not the widget's.
        #expect(handle.latestState?.pointCount == harness.coordinator.recordedPointCount)
        #expect(handle.latestState?.horizontalAccuracy == 9)
    }

    @Test("Reduced accuracy reaches the Lock Screen without ending the recording")
    func reducedAccuracyReachesTheActivity() async throws {
        let (harness, host, manager) = try makeHarness()
        await harness.coordinator.startRecording()
        let handle = try #require(host.created.first)

        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.fullAccuracyDenied = true
        harness.provider.emit(diagnostic)
        try await waitUntil("reduced accuracy") { harness.coordinator.isPreciseLocationDenied }
        await manager.flushPendingWork()

        #expect(handle.latestState?.reducedAccuracy == true)
        #expect(harness.coordinator.phase.isActive)
    }

    @Test("Stopping says so, then ends the activity, and only after the recording is closed")
    func stopEndsTheActivity() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let handle = try #require(host.created.first)
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }

        harness.clock.advance(1_800)
        await harness.coordinator.stopRecording()

        #expect(handle.states.contains { $0.status == .stopping })
        #expect(handle.endCount == 1)
        // And the recording itself finished exactly as it always did.
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.provider.sessionsOutstanding == 0)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt == harness.clock.now)
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
    }

    @Test("Stopping twice ends the activity once")
    func doubleStopEndsOnce() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        let handle = try #require(host.created.first)

        await harness.coordinator.stopRecording()
        await harness.coordinator.stopRecording()

        #expect(handle.endCount == 1)
    }

    @Test("A fatal recording failure ends the activity too")
    func failureEndsTheActivity() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        let handle = try #require(host.created.first)

        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.authorizationDenied = true
        harness.provider.emit(diagnostic)

        try await waitUntil("failed") { harness.coordinator.phase == .failed(.permissionDenied) }
        try await waitUntil("activity ended") { handle.endCount == 1 }
        #expect(handle.endCount == 1)
    }

    @Test("An abandoned recovery ends the activity rather than leaving it running")
    func abandonEndsTheActivity() async throws {
        let host = FakeActivityHost()
        let manager = RecordingLiveActivityManager(host: host)
        let harness = try RecordingHarness(liveActivity: manager)
        // A marker pointing at a session that is not in the store.
        let sessionID = UUID()
        harness.markerStore.save(RecoveryMarker(sessionID: sessionID, startedAt: testBase))
        let stray = FakeActivityHandle(sessionID: sessionID)
        host.preexisting = [stray]

        harness.coordinator.restoreInterruptedRecordingIfNeeded()

        try await waitUntil("abandoned") {
            harness.coordinator.phase == .failed(.recoveredSessionMissing)
        }
        try await waitUntil("activity ended") { stray.isEnded }
        #expect(harness.provider.sessionsOutstanding == 0)
    }

    // MARK: - Recording survives ActivityKit

    @Test("ActivityKit refusing to start does not stop the recording")
    func activityKitFailureDoesNotStopRecording() async throws {
        let host = FakeActivityHost()
        host.requestError = ActivityKitRefused()
        let harness = try RecordingHarness(liveActivity: RecordingLiveActivityManager(host: host))

        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        #expect(harness.coordinator.phase.isActive)

        harness.deliver(sample(1))
        harness.deliver(sample(30, positionB))
        try await waitUntil("two fixes") { harness.coordinator.recordedPointCount == 2 }

        harness.clock.advance(600)
        await harness.coordinator.stopRecording()

        // The recording is complete and correct, and no failure was reported.
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.lastFinishedSessionID == sessionID)
        let samples = try await harness.store.samples(sessionID: sessionID)
        #expect(samples.count == 2)
        #expect(try await #require(harness.store.sessionSnapshot(id: sessionID)).endedAt != nil)
    }

    @Test("Live Activities being switched off does not stop the recording")
    func disabledActivitiesDoNotStopRecording() async throws {
        let host = FakeActivityHost()
        host.areActivitiesEnabled = false
        let harness = try RecordingHarness(liveActivity: RecordingLiveActivityManager(host: host))

        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.deliver(sample(1))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }
        await harness.coordinator.stopRecording()

        #expect(host.requested.isEmpty)
        #expect(harness.coordinator.phase == .idle)
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 1)
    }

    @Test("A dismissed Live Activity leaves the recording untouched")
    func dismissedActivityDoesNotAffectRecording() async throws {
        let (harness, host, _) = try makeHarness()
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        // The user swipes the activity away: the system forgets it, GPeX does not.
        host.preexisting = []

        harness.deliver(sample(1))
        harness.deliver(sample(60, positionB))
        try await waitUntil("two fixes") { harness.coordinator.recordedPointCount == 2 }
        await harness.coordinator.stopRecording()

        #expect(try await harness.store.pointCount(sessionID: sessionID) == 2)
        #expect(harness.coordinator.phase == .idle)
    }

    // MARK: - Recovery

    @Test("A restored recording rejoins its own Live Activity by session id")
    func restoreReassociatesBySessionID() async throws {
        let first = try RecordingHarness()
        await first.coordinator.startRecording()
        let sessionID = try #require(first.coordinator.state.activeRecording?.sessionID)
        first.deliver(sample(1))
        try await waitUntil("first fix") { first.coordinator.recordedPointCount == 1 }

        // Relaunch: a fresh coordinator over the same store, marker and a host that still
        // has the original activity plus an unrelated leftover.
        let host = FakeActivityHost()
        let match = FakeActivityHandle(sessionID: sessionID)
        let unrelated = FakeActivityHandle(sessionID: UUID())
        host.preexisting = [unrelated, match]
        let manager = RecordingLiveActivityManager(host: host)
        let clock = MutableClock(testBase.addingTimeInterval(900))
        let restored = RecordingCoordinator(
            trackStore: first.store,
            markerStore: first.markerStore,
            provider: TestLocationUpdatesProvider(),
            liveActivity: manager,
            now: { clock.now }
        )

        restored.restoreInterruptedRecordingIfNeeded()
        try await waitUntil("rejoined") { restored.recordedPointCount == 1 }
        await manager.flushPendingWork()

        // Reassociated, not recreated, and matched by id rather than position.
        #expect(host.requested.isEmpty)
        #expect(!match.isEnded)
        #expect(match.latestState?.pointCount == 1)
        #expect(unrelated.isEnded)
    }

    @Test("Recovery succeeds with no Live Activity to rejoin at all")
    func restoreWithoutAnyActivity() async throws {
        let first = try RecordingHarness()
        await first.coordinator.startRecording()
        let sessionID = try #require(first.coordinator.state.activeRecording?.sessionID)
        first.deliver(sample(1))
        try await waitUntil("first fix") { first.coordinator.recordedPointCount == 1 }

        let host = FakeActivityHost()
        let manager = RecordingLiveActivityManager(host: host)
        let clock = MutableClock(testBase.addingTimeInterval(900))
        let restored = RecordingCoordinator(
            trackStore: first.store,
            markerStore: first.markerStore,
            provider: TestLocationUpdatesProvider(),
            liveActivity: manager,
            now: { clock.now }
        )

        restored.restoreInterruptedRecordingIfNeeded()

        // The GPS track is authoritative: recovery does not wait for, or need, ActivityKit.
        #expect(restored.phase.isActive)
        #expect(restored.startedAt == testBase)
        try await waitUntil("rejoined") { restored.recordedPointCount == 1 }
        #expect(host.requested.isEmpty)

        // Recording continues into the same session.
        clock.now = testBase.addingTimeInterval(900)
        restored.restoreInterruptedRecordingIfNeeded()
        #expect(try await first.store.pointCount(sessionID: sessionID) == 1)
    }

    @Test("Bringing the app forward recreates a Live Activity that went missing")
    func foregroundRecreatesMissingActivity() async throws {
        let host = FakeActivityHost()
        host.areActivitiesEnabled = false
        let manager = RecordingLiveActivityManager(host: host)
        let harness = try RecordingHarness(liveActivity: manager)

        // Recording starts while Live Activities are unavailable.
        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        harness.deliver(sample(1, accuracy: 5))
        try await waitUntil("first fix") { harness.coordinator.recordedPointCount == 1 }
        #expect(host.requested.isEmpty)

        // The user turns them on and reopens GPeX.
        host.areActivitiesEnabled = true
        harness.coordinator.reconcileLiveActivity()
        await manager.flushPendingWork()

        #expect(host.requested.count == 1)
        #expect(host.requested[0].sessionID == sessionID)
        #expect(host.created.first?.latestState?.pointCount == 1)
    }

    @Test("With no recording running, reconciling does nothing")
    func reconcileWhileIdleDoesNothing() async throws {
        let (harness, host, _) = try makeHarness()
        harness.coordinator.reconcileLiveActivity()
        #expect(host.requested.isEmpty)
        #expect(harness.coordinator.phase == .idle)
    }
}

// MARK: - Change helper

extension RecordingLiveSnapshot {
    /// The kinds of change that should reach ActivityKit.
    nonisolated enum Change: Sendable, CustomStringConvertible {
        case status
        case accuracy
        case pointCount
        case reducedAccuracy

        var description: String {
            switch self {
            case .status: "status"
            case .accuracy: "accuracy"
            case .pointCount: "pointCount"
            case .reducedAccuracy: "reducedAccuracy"
            }
        }
    }

    func applying(_ change: Change) -> RecordingLiveSnapshot {
        var copy = self
        switch change {
        case .status: copy.phase = .stationary
        case .accuracy: copy.horizontalAccuracy = (horizontalAccuracy ?? 0) + 5
        case .pointCount: copy.pointCount += 1
        case .reducedAccuracy: copy.reducedAccuracy = !reducedAccuracy
        }
        return copy
    }
}
