import CoreLocation
import Foundation

/// How useful a fix is likely to be for positioning photographs.
///
/// These buckets drive UI wording and export preferences. They are deliberately
/// coarse: a reported horizontal accuracy is a radius estimate, not a guarantee
/// that the true position lies within it.
nonisolated enum LocationQuality: Sendable, Comparable, CaseIterable {
    case poor
    case usable
    case good
    case excellent

    init(horizontalAccuracy: Double) {
        switch horizontalAccuracy {
        case ..<0: self = .poor
        case ...10: self = .excellent
        case ...20: self = .good
        case ...50: self = .usable
        default: self = .poor
        }
    }

    var label: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .usable: "Usable"
        case .poor: "Poor"
        }
    }
}

/// A single Core Location observation, reduced to a `Sendable` value that is safe
/// to hand to persistence and to the exporter.
///
/// Optional fields are `nil` when Core Location reported the corresponding value
/// as invalid. Nothing here is derived or interpolated: every `LocationSample`
/// corresponds to one real `CLLocation`.
nonisolated struct LocationSample: Sendable, Equatable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    /// Present only when `verticalAccuracy` was valid.
    var altitude: Double?
    var horizontalAccuracy: Double
    var verticalAccuracy: Double?
    /// Present only when Core Location reported a valid speed.
    var speed: Double?
    /// Present only when Core Location reported a valid course.
    var course: Double?
    /// True when this fix arrived on an update that reported the device stationary.
    var stationary: Bool
    var isSimulatedBySoftware: Bool?
    var isProducedByAccessory: Bool?

    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        verticalAccuracy: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil,
        stationary: Bool = false,
        isSimulatedBySoftware: Bool? = nil,
        isProducedByAccessory: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.stationary = stationary
        self.isSimulatedBySoftware = isSimulatedBySoftware
        self.isProducedByAccessory = isProducedByAccessory
    }

    /// Converts a `CLLocation` into a sample, rejecting values that cannot describe
    /// a real position.
    ///
    /// This performs *intrinsic* validation only — whether the numbers themselves are
    /// usable. Whether the fix makes sense for a particular recording (plausible
    /// timestamp, not a stale cached location) is checked by `RecordingCoordinator`,
    /// which is the only place that knows the recording's start time and the last
    /// accepted sample.
    init?(location: CLLocation, stationary: Bool) {
        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        // A negative horizontal accuracy means the coordinate is invalid.
        guard location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else { return nil }

        let verticalAccuracyIsValid = location.verticalAccuracy.isFinite && location.verticalAccuracy > 0
        let speedIsValid = location.speed >= 0 && location.speedAccuracy >= 0
        let courseIsValid = location.course >= 0 && location.courseAccuracy >= 0

        self.init(
            timestamp: location.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: verticalAccuracyIsValid && location.altitude.isFinite ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: verticalAccuracyIsValid ? location.verticalAccuracy : nil,
            speed: speedIsValid ? location.speed : nil,
            course: courseIsValid ? location.course : nil,
            stationary: stationary,
            isSimulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: location.sourceInformation?.isProducedByAccessory
        )
    }

    var quality: LocationQuality { LocationQuality(horizontalAccuracy: horizontalAccuracy) }

    /// Metres between two fixes, on the sphere Core Location itself measures on.
    ///
    /// Pure arithmetic: `CLLocation` here is a value, not a request for hardware.
    func distance(from other: LocationSample) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    /// True when the fix suggests the photographer was walking rather than standing.
    ///
    /// Used to decide whether the exporter may safely extend a coordinate backwards
    /// to the session start. Absent speed information counts as "not moving", because
    /// a missing speed is not evidence of movement.
    func indicatesMovement(fasterThan threshold: Double) -> Bool {
        guard let speed else { return false }
        return speed > threshold
    }
}
