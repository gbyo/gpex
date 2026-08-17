import Foundation
import SwiftData
import OSLog

nonisolated enum TrackStoreError: Error, Equatable {
    /// The recovery marker referred to a session that is not in the database.
    case sessionNotFound(UUID)
    /// The session exists but has already been closed.
    case sessionAlreadyEnded(UUID)
}

/// All SwiftData access happens here.
///
/// A `@ModelActor` gives the store its own `ModelContext` on its own executor, so
/// recording writes never block the main actor and the UI's `@Query` views stay on
/// the main context. Nothing that crosses this boundary is a SwiftData model — only
/// `Sendable` snapshots and `LocationSample` values.
@ModelActor
actor TrackStore {
    /// Session IDs already confirmed to exist, so appending points does not refetch.
    private var verifiedSessionIDs: Set<UUID> = []

    // MARK: - Sessions

    func createSession(id: UUID, name: String, startedAt: Date) throws {
        let session = TrackSession(id: id, name: name, startedAt: startedAt)
        modelContext.insert(session)
        try modelContext.save()
        verifiedSessionIDs.insert(id)
        Log.persistence.info("Created session \(id, privacy: .public)")
    }

    /// Confirms a recovered session still exists and is still open.
    ///
    /// Throws rather than recreating anything: if the row is gone, the marker is
    /// stale and the recording must be abandoned rather than invented.
    @discardableResult
    func requireOpenSession(id: UUID) throws -> TrackSessionSnapshot {
        guard let session = try fetchSession(id: id) else {
            throw TrackStoreError.sessionNotFound(id)
        }
        guard session.endedAt == nil else {
            throw TrackStoreError.sessionAlreadyEnded(id)
        }
        verifiedSessionIDs.insert(id)
        return TrackSessionSnapshot(session)
    }

    func endSession(id: UUID, endedAt: Date) throws {
        guard let session = try fetchSession(id: id) else {
            throw TrackStoreError.sessionNotFound(id)
        }
        // Idempotent: a second Stop must not move an already-recorded end time.
        guard session.endedAt == nil else { return }
        session.endedAt = endedAt
        try modelContext.save()
        Log.persistence.info("Closed session \(id, privacy: .public)")
    }

    func sessionSnapshot(id: UUID) throws -> TrackSessionSnapshot? {
        try fetchSession(id: id).map(TrackSessionSnapshot.init)
    }

    /// Sessions that were never closed, newest first.
    func openSessionIDs() throws -> [UUID] {
        var descriptor = FetchDescriptor<TrackSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id]
        return try modelContext.fetch(descriptor).map(\.id)
    }

    func rename(sessionID: UUID, to name: String) throws {
        guard let session = try fetchSession(id: sessionID) else {
            throw TrackStoreError.sessionNotFound(sessionID)
        }
        session.name = name
        try modelContext.save()
    }

    func setCameraClockOffset(sessionID: UUID, seconds: Double) throws {
        guard let session = try fetchSession(id: sessionID) else {
            throw TrackStoreError.sessionNotFound(sessionID)
        }
        session.cameraClockOffsetSeconds = seconds
        try modelContext.save()
    }

    /// Deletes a session and every point belonging to it.
    ///
    /// `TrackPoint` has no relationship to `TrackSession`, so the points must be
    /// deleted explicitly. Doing both in one save keeps them from diverging.
    func deleteSession(id: UUID) throws {
        try modelContext.delete(model: TrackPoint.self, where: #Predicate { $0.sessionID == id })
        try modelContext.delete(model: TrackSession.self, where: #Predicate { $0.id == id })
        try modelContext.save()
        verifiedSessionIDs.remove(id)
        Log.persistence.info("Deleted session \(id, privacy: .public) and its points")
    }

    // MARK: - Points

    /// Persists raw observations and returns the session's new total point count.
    ///
    /// Verifies the session exists once, then trusts the cache; an unknown session
    /// throws so the caller can abandon a stale recovery instead of writing orphans.
    @discardableResult
    func append(_ samples: [LocationSample], sessionID: UUID) throws -> Int {
        guard !samples.isEmpty else { return try pointCount(sessionID: sessionID) }
        if !verifiedSessionIDs.contains(sessionID) {
            guard try fetchSession(id: sessionID) != nil else {
                throw TrackStoreError.sessionNotFound(sessionID)
            }
            verifiedSessionIDs.insert(sessionID)
        }
        for sample in samples {
            modelContext.insert(TrackPoint(sessionID: sessionID, sample: sample))
        }
        try modelContext.save()
        return try pointCount(sessionID: sessionID)
    }

    /// Records that the device went stationary at a position already persisted.
    ///
    /// Core Location sometimes reports `stationary` on an update that carries no
    /// location. That is still a real observation about the last known position, so
    /// the flag is applied to the most recent point — but only if that point is
    /// recent enough that labelling it would not be a guess.
    @discardableResult
    func markLatestPointStationary(sessionID: UUID, notOlderThan cutoff: Date) throws -> Bool {
        var descriptor = FetchDescriptor<TrackPoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let latest = try modelContext.fetch(descriptor).first else { return false }
        guard latest.timestamp >= cutoff else { return false }
        guard !latest.stationary else { return false }
        latest.stationary = true
        try modelContext.save()
        return true
    }

    func pointCount(sessionID: UUID) throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<TrackPoint>(predicate: #Predicate { $0.sessionID == sessionID })
        )
    }

    /// Every raw observation for a session in chronological order, as values.
    func samples(sessionID: UUID) throws -> [LocationSample] {
        let descriptor = FetchDescriptor<TrackPoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(\.sample)
    }

    func summary(sessionID: UUID) throws -> SessionSummary {
        var descriptor = FetchDescriptor<TrackPoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.propertiesToFetch = [\.horizontalAccuracy]
        return SessionSummary(accuracies: try modelContext.fetch(descriptor).map(\.horizontalAccuracy))
    }

    /// Everything the exporter needs, fetched together so the two cannot disagree.
    func exportInput(sessionID: UUID) throws -> (session: TrackSessionSnapshot, samples: [LocationSample])? {
        guard let snapshot = try sessionSnapshot(id: sessionID) else { return nil }
        return (snapshot, try samples(sessionID: sessionID))
    }

    // MARK: - Private

    private func fetchSession(id: UUID) throws -> TrackSession? {
        var descriptor = FetchDescriptor<TrackSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
