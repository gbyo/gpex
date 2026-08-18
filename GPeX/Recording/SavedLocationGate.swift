import CoreLocation
import Foundation

/// Decides which of the fixes Core Location delivers are worth writing down.
///
/// This is the whole implementation of the saved-location interval, and it is a pure
/// value on purpose: no clock of its own, no timer, no `requestLocation()`, no Core
/// Motion. It is handed a fix that Core Location chose to deliver and answers one
/// question — save it, or let it go. Everything about *when* fixes arrive remains
/// Apple's business.
///
/// The interval is a floor, not a schedule. Waiting it out is the normal case, but four
/// things are more informative than a stopwatch and are allowed through early:
///
/// * the first fix of a recording, so a session is never empty while it waits;
/// * a displacement large enough to be real given how precise the two fixes claim to be;
/// * an accuracy that has improved enough to materially change where the photographer was;
/// * Core Location saying the device has become stationary, and the first fix that shows
///   it is no longer stationary.
///
/// The state it keeps is only ever advanced by `noteSaved(_:)`, which the coordinator
/// calls after a write has actually succeeded — so a failed write does not make the gate
/// believe the interval has restarted.
nonisolated struct SavedLocationGate: Sendable, Equatable {

    /// Why a fix was let through. Carried for logging and for tests that need to assert
    /// on *which* rule fired rather than merely that something did.
    enum Reason: String, Sendable, Equatable {
        /// The recording had nothing at all yet.
        case firstFix
        /// The chosen interval has elapsed since the last saved fix.
        case intervalElapsed
        /// The photographer has demonstrably moved, sooner than the interval.
        case meaningfulMovement
        /// This fix pins the position down materially better than the last saved one.
        case improvedAccuracy
        /// Core Location has reported the device stationary.
        case becameStationary
        /// The first usable fix after a stationary stretch.
        case resumedAfterStationary
    }

    enum Decision: Sendable, Equatable {
        case save(Reason)
        /// Arrived inside the interval and said nothing new. Not an error, and not a
        /// rejected fix — simply one that is not worth a row.
        case skip
    }

    /// The smallest displacement ever treated as movement, however precise the fixes
    /// claim to be. A phone lying on a table produces a metre or two of wander, and no
    /// realistic sideline relocation is under ten metres.
    static let displacementFloor: CLLocationDistance = 10

    /// How much better an accuracy has to get before it counts as material: at least
    /// halved, *and* at least this many metres tighter.
    ///
    /// Both conditions are needed. The ratio alone would fire on 2 m improving to 0.9 m,
    /// which changes nothing anyone can see; the absolute figure alone would fire on
    /// 800 m improving to 790 m, which is still useless.
    static let accuracyImprovementFloor: CLLocationDistance = 5
    static let accuracyImprovementFactor: Double = 0.5

    /// The cadence this recording is running at. Fixed for the lifetime of a recording,
    /// including one resumed from a recovery marker.
    let interval: LocationSaveInterval

    /// The last fix actually written. `nil` until the first one succeeds.
    private(set) var lastSaved: LocationSample?

    /// Whether Core Location's most recent word on the matter was "stationary".
    ///
    /// Tracked separately from `lastSaved.stationary` because a stationary report can
    /// arrive with no coordinate at all, which changes nothing about the last saved fix
    /// but is still Core Location telling us where the device is.
    private(set) var isStationary = false

    init(interval: LocationSaveInterval) {
        self.interval = interval
    }

    // MARK: - Deciding

    func decide(_ candidate: LocationSample) -> Decision {
        guard let lastSaved else { return .save(.firstFix) }

        // Movement resuming is the single most useful thing a fix can say after a quiet
        // stretch, and it is exactly the moment the interval would otherwise hide.
        if isStationary, !candidate.stationary { return .save(.resumedAfterStationary) }

        // The arrival of stationary information, rather than every fix that repeats it.
        // Once the recording is known to be stationary the interval governs again, so a
        // device parked for an hour does not fill the track with one square metre.
        if candidate.stationary, !isStationary { return .save(.becameStationary) }

        if candidate.timestamp.timeIntervalSince(lastSaved.timestamp) >= interval.seconds {
            return .save(.intervalElapsed)
        }

        if Self.isMeaningfulDisplacement(from: lastSaved, to: candidate) {
            return .save(.meaningfulMovement)
        }

        if Self.isMateriallyBetterAccuracy(from: lastSaved, to: candidate) {
            return .save(.improvedAccuracy)
        }

        return .skip
    }

    // MARK: - Advancing

    /// Records that a fix really was written. The only thing that restarts the interval.
    mutating func noteSaved(_ sample: LocationSample) {
        lastSaved = sample
        isStationary = sample.stationary
    }

    /// Records a stationary report that carried no coordinate.
    ///
    /// Core Location does this when it stops delivering because the device has not moved.
    /// Nothing was saved, so the interval is untouched — but the next fix that is *not*
    /// stationary is now the first one after a stationary stretch, and gets in early.
    mutating func noteStationaryWithoutLocation() {
        isStationary = true
    }

    // MARK: - The two judgement calls

    /// Whether two fixes are far enough apart for the difference to be movement rather
    /// than noise.
    ///
    /// The threshold comes from the fixes themselves. A horizontal accuracy is a radius
    /// estimate, so two positions can only be confidently distinguished once they are
    /// further apart than their radii combined — 20 m between two ±8 m fixes is real,
    /// while 20 m between two ±50 m fixes is well within what standing still produces.
    /// A fixed `distance > 10` rule would call both of those movement, and would fill a
    /// reduced-accuracy recording with a wandering track of a photographer who never left
    /// the touchline.
    static func isMeaningfulDisplacement(from previous: LocationSample, to candidate: LocationSample) -> Bool {
        let radii = max(0, previous.horizontalAccuracy) + max(0, candidate.horizontalAccuracy)
        return candidate.distance(from: previous) > max(displacementFloor, radii)
    }

    /// Whether a fix pins the position down materially better than the last saved one.
    ///
    /// Worth an early row because the interval is about how often a position changes,
    /// and a much tighter radius on the same position *is* a better answer to where the
    /// photographer was — which is the question every geotagged photo asks.
    static func isMateriallyBetterAccuracy(from previous: LocationSample, to candidate: LocationSample) -> Bool {
        let before = previous.horizontalAccuracy
        let after = candidate.horizontalAccuracy
        guard before > 0, after >= 0 else { return false }
        return after <= before * accuracyImprovementFactor
            && (before - after) >= accuracyImprovementFloor
    }
}
