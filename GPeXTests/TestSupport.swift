import Foundation
import SwiftData
import Testing
@testable import GPeX

/// A fixed instant so every expectation can be written as a literal.
/// `1_786_968_000` is 2026-08-17T12:00:00Z.
nonisolated let testBase = Date(timeIntervalSince1970: 1_786_968_000)

/// Two positions about 55 m apart — far enough that moving between them matters.
nonisolated let positionA = (latitude: 41.8781, longitude: -87.6298)
nonisolated let positionB = (latitude: 41.8786, longitude: -87.6298)
nonisolated let positionC = (latitude: 41.8791, longitude: -87.6290)

nonisolated func sample(
    _ offset: TimeInterval,
    _ position: (latitude: Double, longitude: Double) = positionA,
    accuracy: Double = 8,
    stationary: Bool = false,
    altitude: Double? = nil,
    verticalAccuracy: Double? = nil,
    speed: Double? = nil,
    base: Date = testBase
) -> LocationSample {
    LocationSample(
        timestamp: base.addingTimeInterval(offset),
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: altitude,
        horizontalAccuracy: accuracy,
        verticalAccuracy: verticalAccuracy ?? (altitude != nil ? 4 : nil),
        speed: speed,
        stationary: stationary
    )
}

nonisolated func session(
    name: String = "Test Session",
    start: TimeInterval = 0,
    end: TimeInterval? = nil,
    offsetSeconds: Double = 0,
    base: Date = testBase
) -> TrackSessionSnapshot {
    TrackSessionSnapshot(
        id: UUID(),
        name: name,
        startedAt: base.addingTimeInterval(start),
        endedAt: end.map { base.addingTimeInterval($0) },
        cameraClockOffsetSeconds: offsetSeconds
    )
}

extension GPXTrackPoint {
    /// Seconds from `testBase`, for readable expectations.
    var offsetFromBase: TimeInterval { timestamp.timeIntervalSince(testBase) }
}

/// An in-memory store, isolated per test.
nonisolated func makeTrackStore() throws -> (TrackStore, ModelContainer) {
    let schema = Schema([TrackSession.self, TrackPoint.self])
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
    return (TrackStore(modelContainer: container), container)
}

/// A clock the tests move by hand, so nothing depends on real elapsed time.
@MainActor
final class MutableClock {
    var now: Date
    init(_ now: Date = testBase) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Everything needed to drive a `RecordingCoordinator` with no Core Location.
@MainActor
struct RecordingHarness {
    let container: ModelContainer
    let store: TrackStore
    let provider: TestLocationUpdatesProvider
    let markerStore: RecoveryMarkerStore
    let defaults: UserDefaults
    let clock: MutableClock
    let coordinator: RecordingCoordinator

    init(allowsRestore: Bool = true) throws {
        let (store, container) = try makeTrackStore()
        self.container = container
        self.store = store
        self.provider = TestLocationUpdatesProvider()

        // A throwaway defaults domain so the marker cannot leak between tests.
        let suiteName = "GPeXTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        self.markerStore = RecoveryMarkerStore(defaults: defaults)

        let clock = MutableClock()
        self.clock = clock
        self.coordinator = RecordingCoordinator(
            trackStore: store,
            markerStore: markerStore,
            provider: provider,
            allowsRestore: allowsRestore,
            now: { clock.now }
        )
    }
}

@MainActor
extension RecordingHarness {
    /// Delivers a fix, moving the clock forward to its timestamp first.
    ///
    /// This models what really happens: a fix arrives at about the time it was taken.
    /// Emitting without advancing the clock would hand the coordinator a future-dated
    /// location, which it is right to reject.
    func deliver(_ sample: LocationSample) {
        if sample.timestamp > clock.now { clock.now = sample.timestamp }
        provider.emit(sample)
    }
}

/// Polls a condition instead of sleeping for a fixed interval, so tests are as fast as
/// the work actually is and still fail loudly rather than hanging.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(4))
    }
    Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
}
