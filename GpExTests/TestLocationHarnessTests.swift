import Foundation
import Testing
@testable import GpEx

/// Checks on the scripted-location harness itself.
///
/// The harness feeds the UI tests, so a bug here shows up as a mysterious UI-test
/// failure rather than as an obvious harness failure. `RecordingCoordinator` rejects
/// samples stamped in the future, which is exactly what a mis-rebased script produces.
@Suite("Scripted location harness")
nonisolated struct TestLocationHarnessTests {
    /// The script deliberately disagrees with itself: samples a full second apart,
    /// delivered 50ms apart. Rebasing on the original offsets would stamp the second
    /// and third samples ahead of the clock.
    private func skewedScript() -> [ScriptedLocationEvent] {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func event(_ offset: TimeInterval) -> LocationUpdateEvent {
            LocationUpdateEvent(
                sample: LocationSample(
                    timestamp: base.addingTimeInterval(offset),
                    latitude: 41.8781,
                    longitude: -87.6298,
                    altitude: 42,
                    horizontalAccuracy: 7,
                    verticalAccuracy: 4,
                    speed: 1.4,
                    course: 90,
                    stationary: false
                )
            )
        }
        return (1...3).map { ScriptedLocationEvent(after: .milliseconds(50), event(TimeInterval($0))) }
    }

    private func collectSamples(
        from script: [ScriptedLocationEvent],
        count: Int
    ) async throws -> [(sample: LocationSample, receivedAt: Date)] {
        let provider = TestLocationUpdatesProvider(script: script)
        var received: [(sample: LocationSample, receivedAt: Date)] = []
        for try await event in provider.liveUpdates() {
            if let sample = event.sample {
                received.append((sample, Date()))
            }
            if received.count == count { break }
        }
        return received
    }

    @Test("Scripted samples are never delivered with a future timestamp")
    func skewedScriptIsNotFutureDated() async throws {
        let received = try await collectSamples(from: skewedScript(), count: 3)

        #expect(received.count == 3)
        for (index, delivery) in received.enumerated() {
            #expect(
                delivery.sample.timestamp <= delivery.receivedAt,
                """
                Sample \(index) was stamped \(delivery.sample.timestamp) but delivered at \
                \(delivery.receivedAt), which the coordinator would reject as a future fix.
                """
            )
        }
    }

    @Test("The UI-test script is not future-dated either")
    func uiTestingScriptIsNotFutureDated() async throws {
        let script = TestLocationUpdatesProvider.uiTestingScript()
        let received = try await collectSamples(from: script, count: script.count)

        #expect(received.count == script.count)
        for delivery in received {
            #expect(delivery.sample.timestamp <= delivery.receivedAt)
        }
    }

    @Test("Rebased timestamps still advance in delivery order")
    func rebasedTimestampsAdvance() async throws {
        let received = try await collectSamples(from: skewedScript(), count: 3)

        let timestamps = received.map(\.sample.timestamp)
        #expect(timestamps == timestamps.sorted())
        #expect(Set(timestamps).count == timestamps.count, "Each delivery should carry its own time")
    }

    @Test("A script with no samples is left alone")
    func scriptWithoutSamplesIsUnchanged() async throws {
        var stationary = LocationUpdateEvent(sample: nil)
        stationary.stationary = true
        let provider = TestLocationUpdatesProvider(
            script: [ScriptedLocationEvent(after: .milliseconds(10), stationary)]
        )

        for try await event in provider.liveUpdates() {
            #expect(event.sample == nil)
            #expect(event.stationary)
            break
        }
    }
}
