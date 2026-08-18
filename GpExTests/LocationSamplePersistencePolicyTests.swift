import Foundation
import Testing
@testable import GpEx

/// One metre of latitude, near enough, for writing jitter as a distance.
private let metreOfLatitude = 1.0 / 111_320.0

private func offsetting(
    _ position: (latitude: Double, longitude: Double),
    northMetres: Double
) -> (latitude: Double, longitude: Double) {
    (latitude: position.latitude + northMetres * metreOfLatitude, longitude: position.longitude)
}

@Suite("Location sample persistence policy")
nonisolated struct LocationSamplePersistencePolicyTests {
    private let policy = LocationSamplePersistencePolicy()

    // MARK: - First fix

    @Test("The first usable fix is always kept")
    func firstFixIsAlwaysKept() {
        #expect(policy.decision(for: sample(0), relativeTo: nil) == .firstFix)
        // Even a poor one: a bad position is better than none for a photograph.
        #expect(policy.decision(for: sample(0, accuracy: 300), relativeTo: nil) == .firstFix)
    }

    // MARK: - Jitter

    @Test("A minute of one-second same-place jitter collapses to a handful of points")
    func jitterIsCoalesced() {
        var previous = sample(0, positionA, accuracy: 8)
        var kept = [previous]

        for second in 1...60 {
            // Drift of a couple of metres around one spot, well inside the fixes'
            // own accuracy circle, with accuracy wobbling the way a real receiver's does.
            let drift = Double((second % 5) - 2) * 1.5
            let candidate = sample(
                Double(second),
                offsetting(positionA, northMetres: drift),
                accuracy: 8 + Double(second % 3)
            )
            if policy.shouldPersist(candidate, relativeTo: previous) {
                kept.append(candidate)
                previous = candidate
            }
        }

        // The behaviour that matters: nothing like one point per delivery, but the
        // track is not silent for the whole minute either.
        #expect(kept.count < 10)
        #expect(kept.count >= 2)
    }

    @Test("Jitter is judged against accuracy, not a fixed distance")
    func noiseEnvelopeScalesWithAccuracy() {
        // 20 m apart says nothing when both fixes claim 40 m accuracy…
        let coarse = sample(0, positionA, accuracy: 40)
        let coarseMoved = sample(1, offsetting(positionA, northMetres: 20), accuracy: 40)
        #expect(policy.decision(for: coarseMoved, relativeTo: coarse) == nil)

        // …and a great deal when both claim 5 m.
        let fine = sample(0, positionA, accuracy: 5)
        let fineMoved = sample(1, offsetting(positionA, northMetres: 20), accuracy: 5)
        #expect(policy.decision(for: fineMoved, relativeTo: fine) == .meaningfulDisplacement)
    }

    @Test("A very poor fix cannot suppress a walk across the field")
    func envelopeIsCapped() {
        let vague = sample(0, positionA, accuracy: 500)
        let farAway = sample(5, offsetting(positionA, northMetres: 120), accuracy: 500)
        #expect(policy.decision(for: farAway, relativeTo: vague) == .meaningfulDisplacement)
    }

    // MARK: - Movement

    @Test("A short sideline relocation is kept immediately")
    func shortRelocationSurvives() {
        let standing = sample(0, positionA, accuracy: 8)
        // Fifteen metres along a sideline, one second later: a real move for a
        // photographer, and the kind the filter must not swallow.
        let moved = sample(1, offsetting(positionA, northMetres: 15), accuracy: 8)
        #expect(policy.decision(for: moved, relativeTo: standing) == .meaningfulDisplacement)
    }

    @Test("Meaningful displacement is kept without waiting for an interval")
    func displacementIsImmediate() {
        let previous = sample(0, positionA)
        let moved = sample(0.5, positionB)
        #expect(policy.decision(for: moved, relativeTo: previous) == .meaningfulDisplacement)
    }

    // MARK: - Accuracy

    @Test("A materially better same-place fix is retained")
    func betterAccuracyIsKept() {
        let poor = sample(0, positionA, accuracy: 40)
        let good = sample(1, positionA, accuracy: 8)
        #expect(policy.decision(for: good, relativeTo: poor) == .betterAccuracy)
    }

    @Test("Small accuracy fluctuations are not treated as an improvement")
    func trivialAccuracyChangeIsIgnored() {
        let previous = sample(0, positionA, accuracy: 9)
        #expect(policy.decision(for: sample(1, positionA, accuracy: 8.5), relativeTo: previous) == nil)
        #expect(policy.decision(for: sample(2, positionA, accuracy: 8), relativeTo: previous) == nil)
        // Worse accuracy in the same place is certainly not worth a point.
        #expect(policy.decision(for: sample(3, positionA, accuracy: 30), relativeTo: previous) == nil)
    }

    // MARK: - Stationary semantics

    @Test("An explicit stationary transition is never dropped for being close")
    func stationaryTransitionIsKept() {
        let previous = sample(0, positionA, accuracy: 8)
        let stationaryHere = sample(1, positionA, accuracy: 8, stationary: true)
        #expect(policy.decision(for: stationaryHere, relativeTo: previous) == .stationaryTransition)
    }

    @Test("The first fix after a stationary period is kept however small the move")
    func resumptionIsKept() {
        let stationary = sample(0, positionA, accuracy: 8, stationary: true)
        // Three metres — far inside the noise envelope, but it is what Core Location
        // resumed to tell us, and it is the end of the stationary bridge.
        let resumed = sample(600, offsetting(positionA, northMetres: 3), accuracy: 8)
        #expect(policy.decision(for: resumed, relativeTo: stationary) == .movementResumed)
    }

    @Test("A continuing stationary report is not persisted over and over")
    func repeatedStationaryIsCoalesced() {
        let stationary = sample(0, positionA, accuracy: 8, stationary: true)
        let again = sample(1, offsetting(positionA, northMetres: 1), accuracy: 8, stationary: true)
        #expect(policy.decision(for: again, relativeTo: stationary) == nil)
    }

    // MARK: - Sparse safety observation

    @Test("An occasional observation still lands if Core Location never goes stationary")
    func periodicObservationIsAllowed() {
        let previous = sample(0, positionA, accuracy: 8)
        let soon = sample(5, offsetting(positionA, northMetres: 1), accuracy: 8)
        #expect(policy.decision(for: soon, relativeTo: previous) == nil)

        let muchLater = sample(45, offsetting(positionA, northMetres: 1), accuracy: 8)
        #expect(policy.decision(for: muchLater, relativeTo: previous) == .periodicObservation)
    }
}
