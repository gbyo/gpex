import Foundation
import SwiftData

/// One recording.
///
/// A session is *active* while `endedAt == nil` and its `id` matches the persisted
/// recovery marker. Sessions are never deleted implicitly — an interrupted recording
/// stays in the database until the user deletes it.
@Model
final class TrackSession {
    #Index<TrackSession>([\.startedAt])

    @Attribute(.unique) var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?

    /// `camera time - actual iPhone time`, in seconds.
    ///
    /// Negative when the camera clock is slow, positive when it is fast. Added to
    /// every exported GPX timestamp; never applied to the raw persisted points.
    var cameraClockOffsetSeconds: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date,
        endedAt: Date? = nil,
        cameraClockOffsetSeconds: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cameraClockOffsetSeconds = cameraClockOffsetSeconds
        self.createdAt = createdAt
    }
}

/// A `Sendable` copy of a session, for crossing the `TrackStore` actor boundary and
/// for feeding the exporter (which must stay free of SwiftData and Core Location).
nonisolated struct TrackSessionSnapshot: Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var cameraClockOffsetSeconds: Double

    init(
        id: UUID,
        name: String,
        startedAt: Date,
        endedAt: Date? = nil,
        cameraClockOffsetSeconds: Double = 0
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cameraClockOffsetSeconds = cameraClockOffsetSeconds
    }

    init(_ session: TrackSession) {
        self.init(
            id: session.id,
            name: session.name,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            cameraClockOffsetSeconds: session.cameraClockOffsetSeconds
        )
    }

    var isFinished: Bool { endedAt != nil }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// Aggregates shown on the session detail screen.
nonisolated struct SessionSummary: Sendable, Equatable {
    var pointCount: Int
    /// Median horizontal accuracy, which is more representative than a mean when a
    /// few fixes are badly wrong.
    var typicalHorizontalAccuracy: Double?
    var bestHorizontalAccuracy: Double?

    static let empty = SessionSummary(pointCount: 0)

    init(pointCount: Int, typicalHorizontalAccuracy: Double? = nil, bestHorizontalAccuracy: Double? = nil) {
        self.pointCount = pointCount
        self.typicalHorizontalAccuracy = typicalHorizontalAccuracy
        self.bestHorizontalAccuracy = bestHorizontalAccuracy
    }

    init(accuracies: [Double]) {
        self.pointCount = accuracies.count
        guard !accuracies.isEmpty else {
            self.typicalHorizontalAccuracy = nil
            self.bestHorizontalAccuracy = nil
            return
        }
        let sorted = accuracies.sorted()
        self.typicalHorizontalAccuracy = sorted[sorted.count / 2]
        self.bestHorizontalAccuracy = sorted.first
    }
}
