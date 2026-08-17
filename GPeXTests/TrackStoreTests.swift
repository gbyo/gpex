import Foundation
import Testing
@testable import GPeX

@Suite("Track store")
nonisolated struct TrackStoreTests {
    @Test("A session round-trips through the store")
    func createAndFetch() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)

        let snapshot = try await #require(store.sessionSnapshot(id: id))
        #expect(snapshot.name == "Soccer")
        #expect(snapshot.startedAt == testBase)
        #expect(snapshot.endedAt == nil)
        #expect(snapshot.cameraClockOffsetSeconds == 0)
        #expect(snapshot.isFinished == false)
    }

    @Test("Points are stored against their session and read back in order")
    func appendAndRead() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)

        _ = try await store.append([sample(60, positionB), sample(0, positionA)], sessionID: id)
        #expect(try await store.pointCount(sessionID: id) == 2)

        let samples = try await store.samples(sessionID: id)
        #expect(samples.map(\.timestamp) == [testBase, testBase.addingTimeInterval(60)])
        #expect(samples[0].latitude == positionA.latitude)
    }

    @Test("Appending to an unknown session throws instead of writing orphans")
    func appendToUnknownSessionThrows() async throws {
        let (store, _) = try makeTrackStore()
        let ghost = UUID()
        await #expect(throws: TrackStoreError.sessionNotFound(ghost)) {
            _ = try await store.append([sample(0)], sessionID: ghost)
        }
    }

    @Test("Deleting a session deletes every point that belonged to it")
    func deleteCascades() async throws {
        let (store, _) = try makeTrackStore()
        let doomed = UUID()
        let keeper = UUID()
        try await store.createSession(id: doomed, name: "Doomed", startedAt: testBase)
        try await store.createSession(id: keeper, name: "Keeper", startedAt: testBase)
        _ = try await store.append([sample(0), sample(30), sample(60)], sessionID: doomed)
        _ = try await store.append([sample(0), sample(30)], sessionID: keeper)

        try await store.deleteSession(id: doomed)

        #expect(try await store.sessionSnapshot(id: doomed) == nil)
        #expect(try await store.pointCount(sessionID: doomed) == 0)
        // The other session is untouched.
        #expect(try await store.pointCount(sessionID: keeper) == 2)
    }

    @Test("Ending a session is idempotent")
    func endSessionIsIdempotent() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)

        let firstEnd = testBase.addingTimeInterval(600)
        try await store.endSession(id: id, endedAt: firstEnd)
        // A second Stop must not move the recorded end time.
        try await store.endSession(id: id, endedAt: testBase.addingTimeInterval(9_999))

        let snapshot = try await #require(store.sessionSnapshot(id: id))
        #expect(snapshot.endedAt == firstEnd)
    }

    @Test("A closed session is not offered up for recovery")
    func requireOpenSessionRejectsClosed() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)
        try await store.endSession(id: id, endedAt: testBase.addingTimeInterval(60))

        await #expect(throws: TrackStoreError.sessionAlreadyEnded(id)) {
            try await store.requireOpenSession(id: id)
        }
    }

    @Test("A missing session is reported rather than recreated")
    func requireOpenSessionRejectsMissing() async throws {
        let (store, _) = try makeTrackStore()
        let ghost = UUID()
        await #expect(throws: TrackStoreError.sessionNotFound(ghost)) {
            try await store.requireOpenSession(id: ghost)
        }
    }

    @Test("A location-less stationary report marks the most recent point")
    func marksLatestPointStationary() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)
        _ = try await store.append([sample(0), sample(30)], sessionID: id)

        let marked = try await store.markLatestPointStationary(
            sessionID: id,
            notOlderThan: testBase
        )
        #expect(marked)

        let samples = try await store.samples(sessionID: id)
        #expect(samples[0].stationary == false)
        #expect(samples[1].stationary == true)
    }

    @Test("A stale point is not retroactively labelled stationary")
    func doesNotMarkStalePoint() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)
        _ = try await store.append([sample(0)], sessionID: id)

        // Cutoff is well after the only point, so labelling it would be a guess.
        let marked = try await store.markLatestPointStationary(
            sessionID: id,
            notOlderThan: testBase.addingTimeInterval(600)
        )
        #expect(marked == false)
        #expect(try await store.samples(sessionID: id)[0].stationary == false)
    }

    @Test("The summary reports the median accuracy, not the mean")
    func summaryUsesMedian() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)
        // One wild outlier must not drag the reported figure.
        _ = try await store.append(
            [
                sample(0, accuracy: 6),
                sample(10, accuracy: 8),
                sample(20, accuracy: 9),
                sample(30, accuracy: 500),
            ],
            sessionID: id
        )

        let summary = try await store.summary(sessionID: id)
        #expect(summary.pointCount == 4)
        #expect(summary.typicalHorizontalAccuracy == 9)
        #expect(summary.bestHorizontalAccuracy == 6)
    }

    @Test("Renaming and correcting the clock persist")
    func mutatesMetadata() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Untitled", startedAt: testBase)

        try await store.rename(sessionID: id, to: "Soccer vs Greenwood")
        try await store.setCameraClockOffset(sessionID: id, seconds: -5)

        let snapshot = try await #require(store.sessionSnapshot(id: id))
        #expect(snapshot.name == "Soccer vs Greenwood")
        #expect(snapshot.cameraClockOffsetSeconds == -5)
    }

    @Test("Unfinished sessions can be found again")
    func listsOpenSessions() async throws {
        let (store, _) = try makeTrackStore()
        let open = UUID()
        let closed = UUID()
        try await store.createSession(id: open, name: "Open", startedAt: testBase)
        try await store.createSession(id: closed, name: "Closed", startedAt: testBase)
        try await store.endSession(id: closed, endedAt: testBase.addingTimeInterval(60))

        #expect(try await store.openSessionIDs() == [open])
    }

    @Test("Export input pairs a session with its own points")
    func exportInput() async throws {
        let (store, _) = try makeTrackStore()
        let id = UUID()
        try await store.createSession(id: id, name: "Soccer", startedAt: testBase)
        _ = try await store.append([sample(0), sample(30, positionB)], sessionID: id)

        let input = try await #require(store.exportInput(sessionID: id))
        #expect(input.session.id == id)
        #expect(input.samples.count == 2)
        #expect(try await store.exportInput(sessionID: UUID()) == nil)
    }
}
