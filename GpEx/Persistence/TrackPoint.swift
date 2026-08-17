import Foundation
import SwiftData

/// One raw Core Location observation.
///
/// Only real observations live here. GPX bridge, start and end anchors are generated
/// during export and are never written to the database, so the original data survives
/// a change to the export algorithm.
///
/// `sessionID` is a plain `UUID` rather than a SwiftData relationship on purpose: a
/// background relaunch can begin persisting points from the recovery marker alone,
/// before the `TrackSession` row has been fetched.
@Model
final class TrackPoint {
    #Index<TrackPoint>([\.sessionID], [\.timestamp], [\.sessionID, \.timestamp])

    var id: UUID
    var sessionID: UUID
    var timestamp: Date

    var latitude: Double
    var longitude: Double

    /// Stored only when Core Location reported a valid vertical accuracy.
    var altitude: Double?
    var horizontalAccuracy: Double
    var verticalAccuracy: Double?

    /// Stored only when Core Location considered the value valid.
    var speed: Double?
    var course: Double?

    /// The device was reported stationary on the update that carried this fix.
    var stationary: Bool

    var isSimulatedBySoftware: Bool?
    var isProducedByAccessory: Bool?

    init(id: UUID = UUID(), sessionID: UUID, sample: LocationSample) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = sample.timestamp
        self.latitude = sample.latitude
        self.longitude = sample.longitude
        self.altitude = sample.altitude
        self.horizontalAccuracy = sample.horizontalAccuracy
        self.verticalAccuracy = sample.verticalAccuracy
        self.speed = sample.speed
        self.course = sample.course
        self.stationary = sample.stationary
        self.isSimulatedBySoftware = sample.isSimulatedBySoftware
        self.isProducedByAccessory = sample.isProducedByAccessory
    }

    var sample: LocationSample {
        LocationSample(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed,
            course: course,
            stationary: stationary,
            isSimulatedBySoftware: isSimulatedBySoftware,
            isProducedByAccessory: isProducedByAccessory
        )
    }
}
