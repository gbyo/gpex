import Foundation

/// Decides which Core Location observations are worth writing down.
///
/// Core Location events and persisted track points are two different things.
/// `CLLocationUpdate.liveUpdates(.default)` may deliver at roughly 1 Hz for as long as
/// it believes the device is in motion — including while a photographer stands on a
/// sideline and the coordinate merely wanders inside its own accuracy circle. Every
/// event still has to be *consumed* (authorization, `stationary`, `locationUnavailable`
/// and the rest are only knowable from the events), but a redundant coordinate does not
/// have to become a `TrackPoint`.
///
/// This type is the whole of that decision: a pure function over two samples. It owns no
/// timers, no tasks, no Core Location objects and no persistence, and it never asks
/// Core Location to change what it is doing. Dropping a point saves a SwiftData write,
/// observable-state churn and GPX bulk — it does not, and is not claimed to, turn the
/// GPS receiver down. Power management belongs to Core Location, which suspends
/// delivery by itself once it decides the device is stationary.
///
/// The thresholds below decide whether another observation *adds information*. They are
/// not a claim about whether the physical phone moved; at 8 m accuracy that question has
/// no honest answer.
nonisolated struct LocationSamplePersistencePolicy: Sendable {
    /// Every tuning value, in one place.
    struct Configuration: Sendable, Equatable {
        /// Fraction of the worse of the two reported accuracies that counts as noise.
        /// A displacement smaller than this is indistinguishable from the fixes'
        /// own uncertainty, so it is not evidence of anything.
        var noiseAccuracyFraction: Double = 0.75
        /// Floor for the noise envelope. Below this, even excellent fixes are treated
        /// as "the same place" — otherwise a stationary phone reporting 3 m accuracy
        /// would persist a point for every metre of drift. Deliberately small so a
        /// short sideline relocation still registers.
        var minimumDisplacement: Double = 8
        /// Ceiling for the noise envelope. A 200 m fix must not be allowed to suppress
        /// a genuine walk across the field; past this distance the move is recorded
        /// whatever the reported accuracy claims.
        var maximumDisplacement: Double = 50
        /// A same-place fix is kept when its accuracy radius is at most this fraction
        /// of the previous one — 40 m improving to 8 m is worth having for photo
        /// placement, 9 m improving to 8 m is not.
        var accuracyImprovementFactor: Double = 0.5
        /// …and only when the absolute gain is at least this many metres, so tiny
        /// fluctuations at already-good accuracy do not qualify.
        var minimumAccuracyGain: Double = 5
        /// The sparse safety observation. If Core Location never declares the device
        /// stationary and simply keeps delivering jitter, one point is still kept about
        /// this often, so a long standing period is not a hole in the track. At 20 s
        /// that is three points a minute in the worst case rather than sixty.
        ///
        /// This is evaluated against the timestamps of events that are already
        /// arriving. Nothing here schedules, requests or manufactures a fix.
        var maximumObservationInterval: TimeInterval = 20

        static let standard = Configuration()
    }

    /// Why a candidate was kept. Useful in logs and in tests that want to assert on
    /// behaviour rather than on a count.
    enum Decision: Sendable, Equatable {
        /// The first usable fix of a recording.
        case firstFix
        /// Core Location explicitly reported the device stationary. The exporter needs
        /// this transition to hold the photographer in place instead of interpolating
        /// them across the field for the whole standing period.
        case stationaryTransition
        /// The first valid fix after a stationary period. Kept regardless of distance:
        /// a photographer may have moved only a few metres, and that move is exactly
        /// what the resumed delivery is reporting.
        case movementResumed
        /// Far enough from the last persisted point to be meaningful at this accuracy.
        case meaningfulDisplacement
        /// Same place, but a materially better fix.
        case betterAccuracy
        /// Nothing else fired, but too long has passed since the last persisted point.
        case periodicObservation
    }

    var configuration: Configuration = .standard

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    /// The decision for one candidate, relative to the most recently *persisted*
    /// sample. `nil` means the candidate carries no information the previous point
    /// does not already carry.
    ///
    /// `previous` is the last persisted observation, not the last event received, and
    /// its `stationary` flag is how the policy knows the recording was in Core
    /// Location's stationary state.
    func decision(for candidate: LocationSample, relativeTo previous: LocationSample?) -> Decision? {
        guard let previous else { return .firstFix }

        // An explicit stationary transition is semantic, not geometric. It is never
        // discarded for being close to the previous coordinate — that closeness is the
        // point of it.
        if candidate.stationary, !previous.stationary { return .stationaryTransition }

        // Updates have resumed after Core Location suspended them. Retain the first
        // resumed fix promptly; do not make it clear an arbitrary distance bar first.
        if previous.stationary, !candidate.stationary { return .movementResumed }

        let distance = Self.distance(from: previous, to: candidate)
        if distance >= noiseEnvelope(previous, candidate) { return .meaningfulDisplacement }

        if isMateriallyMoreAccurate(candidate, than: previous) { return .betterAccuracy }

        let elapsed = candidate.timestamp.timeIntervalSince(previous.timestamp)
        if elapsed >= configuration.maximumObservationInterval { return .periodicObservation }

        return nil
    }

    func shouldPersist(_ candidate: LocationSample, relativeTo previous: LocationSample?) -> Bool {
        decision(for: candidate, relativeTo: previous) != nil
    }

    // MARK: - Components

    /// How far apart two fixes must be before the difference means anything.
    ///
    /// Scaled by the worse of the two reported accuracies — two 40 m fixes 20 m apart
    /// say nothing, two 5 m fixes 20 m apart say a great deal — and then clamped, so
    /// the rule degrades sensibly at both ends instead of becoming `distance > 10`.
    func noiseEnvelope(_ previous: LocationSample, _ candidate: LocationSample) -> Double {
        let worst = max(previous.horizontalAccuracy, candidate.horizontalAccuracy)
        let scaled = worst * configuration.noiseAccuracyFraction
        return min(max(scaled, configuration.minimumDisplacement), configuration.maximumDisplacement)
    }

    /// True when the candidate's accuracy radius is enough smaller to change where a
    /// photograph would be placed.
    func isMateriallyMoreAccurate(_ candidate: LocationSample, than previous: LocationSample) -> Bool {
        let gain = previous.horizontalAccuracy - candidate.horizontalAccuracy
        return gain >= configuration.minimumAccuracyGain
            && candidate.horizontalAccuracy <= previous.horizontalAccuracy * configuration.accuracyImprovementFactor
    }

    /// Great-circle distance in metres, matching `GPXExporter`'s: kept local so the
    /// policy stays a pure function with no Core Location dependency.
    static func distance(from a: LocationSample, to b: LocationSample) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}
