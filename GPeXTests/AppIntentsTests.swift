import AppIntents
import Foundation
import Testing
@testable import GPeX

/// A stand-in for the whole app, so an intent can be performed without one.
///
/// Its existence is the point of `GPeXIntentActions`: if the intents reached into
/// `AppServices` or the coordinator directly, there would be nothing to substitute.
@MainActor
final class StubIntentActions: GPeXIntentActions {
    private(set) var startCount = 0
    private(set) var cameraClockCount = 0

    func startRecording() async { startCount += 1 }
    func openCameraClock() { cameraClockCount += 1 }
}

@Suite("App Intents")
@MainActor
struct AppIntentsTests {

    // MARK: - The production surface

    @Test("Start goes through the normal recording path, not a private one")
    func startUsesTheCoordinator() async throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions

        await actions.startRecording()

        // The same evidence the tap-driven tests use: one recording, one set of Core
        // Location objects, one live-update stream.
        #expect(harness.coordinator.phase.isActive)
        #expect(harness.provider.sessionsCreated == 1)
        #expect(harness.provider.liveUpdateStreamsCreated == 1)

        // And a real row, created by `TrackStore` exactly as a tap would.
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.startedAt == harness.clock.now)
    }

    @Test("Starting again while recording does not create a second session")
    func repeatedStartIsIdempotent() async throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions

        await actions.startRecording()
        let first = try #require(harness.coordinator.state.activeRecording?.sessionID)

        await actions.startRecording()
        await actions.startRecording()

        #expect(harness.coordinator.state.activeRecording?.sessionID == first)
        #expect(harness.provider.sessionsCreated == 1)
        #expect(harness.provider.liveUpdateStreamsCreated == 1)
        #expect(try await harness.store.openSessionIDs() == [first])
    }

    @Test("Starting while a recording is stopping does not create a second session")
    func startDuringStopIsIdempotent() async throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions
        await actions.startRecording()
        let first = try #require(harness.coordinator.state.activeRecording?.sessionID)

        // Stop and start in the same turn: the stop is in flight when the start runs.
        async let stopping: Void = harness.coordinator.stopRecording()
        await actions.startRecording()
        await stopping

        #expect(harness.provider.sessionsCreated == 1)
        // Whatever the interleaving, exactly one session was ever created.
        #expect(try await harness.store.openSessionIDs().isEmpty)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: first))
        #expect(snapshot.endedAt != nil)
    }

    @Test("Start shows the active recording UI by returning to the root screen")
    func startReturnsToTheRecordingScreen() async throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions
        // Somewhere else entirely when the intent fires.
        harness.router.showCameraClock()

        await actions.startRecording()

        // The root is the active recording screen whenever a recording is running.
        #expect(harness.router.path.isEmpty)
        #expect(harness.coordinator.phase.isActive)
    }

    @Test("Camera Clock routes to the Camera Clock screen")
    func cameraClockRoutes() throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions

        actions.openCameraClock()

        #expect(harness.router.path == [.cameraClock])
        // Asking twice does not push a second copy.
        actions.openCameraClock()
        #expect(harness.router.path == [.cameraClock])
    }

    @Test("Camera Clock does not touch the recording")
    func cameraClockLeavesRecordingAlone() async throws {
        let harness = try RecordingHarness()
        let actions = harness.intentActions
        await actions.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)

        actions.openCameraClock()

        #expect(harness.coordinator.state.activeRecording?.sessionID == sessionID)
        #expect(harness.provider.sessionsCreated == 1)
    }

    // MARK: - The dependency boundary

    @Test("Intent dependencies can be replaced with a test implementation")
    func dependenciesAreReplaceable() async throws {
        // `AppDependencyManager` only resolves inside the system's perform flow, so a
        // test substitutes directly. That this is possible at all is the point of the
        // dependency: neither intent can reach anything except what is injected here.
        let stub = StubIntentActions()

        let start = StartRecordingIntent()
        start.actions = stub
        _ = try await start.perform()

        let cameraClock = OpenCameraClockIntent()
        cameraClock.actions = stub
        _ = try await cameraClock.perform()

        #expect(stub.startCount == 1)
        #expect(stub.cameraClockCount == 1)
    }

    @Test("The Start intent always delegates; it never decides whether to start")
    func repeatedIntentInvocationsDelegate() async throws {
        let stub = StubIntentActions()
        let intent = StartRecordingIntent()
        intent.actions = stub

        _ = try await intent.perform()
        _ = try await intent.perform()

        // Two calls through, because idempotence belongs to `RecordingCoordinator`
        // and nowhere else. An intent that filtered here would be a second state
        // machine, and would get it wrong.
        #expect(stub.startCount == 2)
    }

    @Test("The app registers exactly the narrow surface the intents declare")
    func registrationUsesTheNarrowSurface() throws {
        let harness = try RecordingHarness()
        // The same call `AppServices.startProcessServices()` makes. It type-checks
        // only because the production actions and the intents agree on one protocol
        // with two methods on it.
        let actions: any GPeXIntentActions = harness.intentActions
        AppDependencyManager.shared.add(dependency: actions)

        let intent = StartRecordingIntent()
        intent.actions = actions
        #expect(intent.actions is AppIntentActions)
    }

    // MARK: - Declarations

    @Test("Both intents bring GPeX to the foreground")
    func intentsOpenTheApp() {
        #expect(StartRecordingIntent.openAppWhenRun)
        #expect(OpenCameraClockIntent.openAppWhenRun)
    }

    @Test("Shortcut phrases are exposed for both intents and nothing else")
    func shortcutsAreDeclared() {
        // No Stop intent yet, deliberately.
        #expect(GPeXShortcuts.appShortcuts.count == 2)
    }
}
