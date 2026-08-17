import Foundation
import Synchronization

/// One scripted delivery: how long to wait, then what to emit.
nonisolated struct ScriptedLocationEvent: Sendable {
    var delay: Duration
    var event: LocationUpdateEvent

    init(after delay: Duration, _ event: LocationUpdateEvent) {
        self.delay = delay
        self.event = event
    }
}

/// The test implementation of the Core Location seam.
///
/// Two ways to drive it:
/// * unit tests call `emit(_:)` directly for a fully deterministic sequence with no
///   real time passing;
/// * UI-test launches hand it a `script`, which it replays with short delays so the
///   app behaves like a device acquiring a position — with no GPS and no permission
///   alert.
///
/// It also counts live-update streams and outstanding sessions, so tests can assert
/// that a recording never ends up with two streams and that stopping really does
/// release the Core Location sessions.
nonisolated final class TestLocationUpdatesProvider: LocationUpdatesProvider {
    private struct State {
        var updateContinuations: [AsyncThrowingStream<LocationUpdateEvent, any Error>.Continuation] = []
        var diagnosticContinuations: [AsyncStream<SessionDiagnostic>.Continuation] = []
        var liveUpdateStreamsCreated = 0
        var sessionsCreated = 0
        var sessionsOutstanding = 0
    }

    private let state = Mutex(State())
    private let script: [ScriptedLocationEvent]

    init(script: [ScriptedLocationEvent] = []) {
        self.script = script
    }

    // MARK: - LocationUpdatesProvider

    func liveUpdates() -> AsyncThrowingStream<LocationUpdateEvent, any Error> {
        AsyncThrowingStream { continuation in
            state.withLock {
                $0.updateContinuations.append(continuation)
                $0.liveUpdateStreamsCreated += 1
            }
            guard !script.isEmpty else { return }
            let script = script
            let task = Task {
                for step in script {
                    try? await Task.sleep(for: step.delay)
                    if Task.isCancelled { return }
                    continuation.yield(step.event)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func beginSessions() -> any LocationSessionHandles {
        state.withLock {
            $0.sessionsCreated += 1
            $0.sessionsOutstanding += 1
        }
        // `self` rather than the `Mutex` itself: a non-copyable value cannot be captured.
        return TestSessionHandles(
            register: { continuation in
                self.state.withLock { $0.diagnosticContinuations.append(continuation) }
            },
            onInvalidate: {
                self.state.withLock { $0.sessionsOutstanding -= 1 }
            }
        )
    }

    // MARK: - Driving from tests

    func emit(_ event: LocationUpdateEvent) {
        let continuations = state.withLock { $0.updateContinuations }
        for continuation in continuations { continuation.yield(event) }
    }

    func emit(_ sample: LocationSample) {
        emit(LocationUpdateEvent(sample: sample))
    }

    /// Emits a stationary report that carries no coordinate, the way Core Location
    /// does when it stops delivering because the device has not moved.
    func emitStationaryWithoutLocation() {
        var event = LocationUpdateEvent(sample: nil)
        event.stationary = true
        emit(event)
    }

    func emit(_ diagnostic: SessionDiagnostic) {
        let continuations = state.withLock { $0.diagnosticContinuations }
        for continuation in continuations { continuation.yield(diagnostic) }
    }

    func finishUpdates() {
        let continuations = state.withLock { $0.updateContinuations }
        for continuation in continuations { continuation.finish() }
    }

    // MARK: - Assertions

    /// How many times a live-update stream has been created. Must never exceed one per
    /// recording.
    var liveUpdateStreamsCreated: Int { state.withLock { $0.liveUpdateStreamsCreated } }
    var sessionsCreated: Int { state.withLock { $0.sessionsCreated } }
    /// Sessions created but not yet invalidated. Must be zero once a recording stops.
    var sessionsOutstanding: Int { state.withLock { $0.sessionsOutstanding } }
}

/// Stand-in for the real Core Location sessions.
nonisolated final class TestSessionHandles: LocationSessionHandles {
    private let register: @Sendable (AsyncStream<SessionDiagnostic>.Continuation) -> Void
    private let onInvalidate: @Sendable () -> Void
    private let invalidated = Mutex(false)
    private let continuation = Mutex<AsyncStream<SessionDiagnostic>.Continuation?>(nil)

    init(
        register: @escaping @Sendable (AsyncStream<SessionDiagnostic>.Continuation) -> Void,
        onInvalidate: @escaping @Sendable () -> Void
    ) {
        self.register = register
        self.onInvalidate = onInvalidate
    }

    func diagnostics() -> AsyncStream<SessionDiagnostic> {
        AsyncStream { continuation in
            self.continuation.withLock { $0 = continuation }
            register(continuation)
        }
    }

    func invalidate() {
        let alreadyInvalidated = invalidated.withLock { value -> Bool in
            let previous = value
            value = true
            return previous
        }
        guard !alreadyInvalidated else { return }
        continuation.withLock { $0?.finish() }
        onInvalidate()
    }
}

// MARK: - UI test script

extension TestLocationUpdatesProvider {
    /// The sequence a UI-test launch replays: a couple of moving fixes near a field,
    /// then stationary. Enough for the active-recording screen to show a real accuracy
    /// and point count without waiting on hardware.
    static func uiTestingScript() -> [ScriptedLocationEvent] {
        let base = Date()
        func sample(_ offset: TimeInterval, _ latitude: Double, _ longitude: Double, stationary: Bool) -> LocationSample {
            LocationSample(
                timestamp: base.addingTimeInterval(offset),
                latitude: latitude,
                longitude: longitude,
                altitude: 42,
                horizontalAccuracy: 7,
                verticalAccuracy: 4,
                speed: stationary ? 0 : 1.4,
                course: 90,
                stationary: stationary
            )
        }
        return [
            ScriptedLocationEvent(after: .milliseconds(400), LocationUpdateEvent(sample: sample(1, 41.8781, -87.6298, stationary: false))),
            ScriptedLocationEvent(after: .milliseconds(400), LocationUpdateEvent(sample: sample(2, 41.8782, -87.6297, stationary: false))),
            ScriptedLocationEvent(after: .milliseconds(400), LocationUpdateEvent(sample: sample(3, 41.8783, -87.6296, stationary: true))),
        ]
    }
}
