import CoreLocation
import Foundation
import Testing
@testable import GPeX

/// The saved-location interval, tested as the pure value it is.
///
/// Everything here runs with no clock, no store and no Core Location: the gate is handed
/// fixes and asked what it would do with them. The coordinator-level suite alongside this
/// one then checks that a real recording actually behaves that way.
@Suite("Saved-location gate")
nonisolated struct SavedLocationGateTests {

    /// A fix `meters` north of `positionA`, for the wander a stationary phone produces.
    private func drifted(_ meters: Double) -> (latitude: Double, longitude: Double) {
        (latitude: positionA.latitude + meters / 111_320, longitude: positionA.longitude)
    }

    private func gate(
        _ interval: LocationSaveInterval = .default,
        seeded: LocationSample? = sample(0)
    ) -> SavedLocationGate {
        var gate = SavedLocationGate(interval: interval)
        if let seeded { gate.noteSaved(seeded) }
        return gate
    }

    // MARK: - The interval itself

    @Test("The default is thirty seconds, and it is the one marked recommended")
    func defaultIsThirtySeconds() {
        #expect(LocationSaveInterval.default == .thirtySeconds)
        #expect(LocationSaveInterval.default.seconds == 30)
        #expect(LocationSaveInterval.thirtySeconds.isRecommended)
        let recommended = LocationSaveInterval.allCases.filter(\.isRecommended)
        #expect(recommended == [.thirtySeconds])
    }

    @Test("Exactly four intervals are offered, in ascending order")
    func fourIntervals() {
        #expect(LocationSaveInterval.allCases.map(\.rawValue) == [10, 20, 30, 60])
        #expect(LocationSaveInterval.allCases.map(\.seconds) == [10, 20, 30, 60])
    }

    @Test("Every interval reads as a plain phrase, and the recommended one says so")
    func intervalsAreLabelled() {
        #expect(LocationSaveInterval.tenSeconds.label == "10 seconds")
        #expect(LocationSaveInterval.twentySeconds.label == "20 seconds")
        #expect(LocationSaveInterval.thirtySeconds.label == "30 seconds")
        #expect(LocationSaveInterval.oneMinute.label == "1 minute")

        #expect(LocationSaveInterval.thirtySeconds.pickerLabel == "30 seconds (Recommended)")
        #expect(LocationSaveInterval.tenSeconds.pickerLabel == "10 seconds")
        #expect(LocationSaveInterval.oneMinute.cadenceDescription == "Saving a location every 1 minute")
    }

    @Test("An absent or unrecognised stored value resolves to the default, never to zero")
    func storedSecondsFallBack() {
        // `0` is what `UserDefaults.integer(forKey:)` returns for a key never written.
        #expect(LocationSaveInterval(storedSeconds: 0) == .default)
        #expect(LocationSaveInterval(storedSeconds: 45) == .default)
        #expect(LocationSaveInterval(storedSeconds: -1) == .default)
        #expect(LocationSaveInterval(storedSeconds: 3_600) == .default)
        // And a value it does recognise is honoured exactly.
        for interval in LocationSaveInterval.allCases {
            #expect(LocationSaveInterval(storedSeconds: interval.rawValue) == interval)
        }
    }

    // MARK: - First fix

    @Test("The very first fix is always saved, whatever the interval")
    func firstFixIsAlwaysSaved() {
        for interval in LocationSaveInterval.allCases {
            var gate = SavedLocationGate(interval: interval)
            #expect(gate.decide(sample(0)) == .save(.firstFix))
            // Nothing is remembered until the coordinator confirms the write.
            #expect(gate.lastSaved == nil)
            gate.noteSaved(sample(0))
            #expect(gate.lastSaved == sample(0))
        }
    }

    @Test("A write that never happened does not restart the interval")
    func onlyConfirmedWritesAdvanceTheGate() {
        var gate = SavedLocationGate(interval: .thirtySeconds)
        #expect(gate.decide(sample(0)) == .save(.firstFix))
        // The append failed, so `noteSaved` was never called: the next fix is still the
        // first one, rather than being coalesced against a row that does not exist.
        #expect(gate.decide(sample(3)) == .save(.firstFix))
    }

    // MARK: - Coalescing

    @Test("Fixes inside the interval at the same place are coalesced", arguments: LocationSaveInterval.allCases)
    func coalescesInsideTheInterval(_ interval: LocationSaveInterval) {
        let gate = self.gate(interval)
        // Every second up to but not including the interval, with a metre of wander.
        for second in 1..<Int(interval.seconds) {
            let candidate = sample(TimeInterval(second), drifted(1))
            #expect(gate.decide(candidate) == .skip, "\(interval.label) saved at \(second)s")
        }
    }

    @Test("A fix at or after the interval is saved", arguments: LocationSaveInterval.allCases)
    func savesOnceTheIntervalElapses(_ interval: LocationSaveInterval) {
        let gate = self.gate(interval)
        #expect(gate.decide(sample(interval.seconds, drifted(1))) == .save(.intervalElapsed))
        #expect(gate.decide(sample(interval.seconds + 1, drifted(1))) == .save(.intervalElapsed))
    }

    @Test("A longer interval coalesces everything a shorter one would have kept")
    func longerIntervalsAreStrictlyQuieter() {
        // 25 seconds in: kept at ten and twenty seconds, coalesced at thirty and a minute.
        let candidate = sample(25, drifted(1))
        #expect(gate(.tenSeconds).decide(candidate) == .save(.intervalElapsed))
        #expect(gate(.twentySeconds).decide(candidate) == .save(.intervalElapsed))
        #expect(gate(.thirtySeconds).decide(candidate) == .skip)
        #expect(gate(.oneMinute).decide(candidate) == .skip)
    }

    // MARK: - Meaningful movement

    @Test("A displacement well beyond both accuracy radii is saved early")
    func meaningfulMovementOverridesTheInterval() {
        // 55 m apart, each fix claiming ±8 m: comfortably outside the combined radii.
        let gate = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 8))
        let moved = sample(3, positionB, accuracy: 8)
        #expect(gate.decide(moved) == .save(.meaningfulMovement))
    }

    /// The rule this replaces would have called every one of these movement.
    @Test("Displacement is judged against the accuracy, not against a fixed ten metres")
    func displacementUsesAccuracy() {
        // 55 m between two ±50 m fixes is well inside what standing still produces, even
        // though it is far more than ten metres.
        let coarse = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 50))
        #expect(coarse.decide(sample(3, positionB, accuracy: 50)) == .skip)

        // The very same 55 m between two precise fixes is real movement.
        let precise = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 5))
        #expect(precise.decide(sample(3, positionB, accuracy: 5)) == .save(.meaningfulMovement))
    }

    @Test("Sub-ten-metre wander is never movement, however precise the fixes claim to be")
    func floorHoldsForImplausiblyPreciseFixes() {
        // Two fixes claiming ±0 m and 4 m apart. Without the floor the combined radii
        // would be zero and this would read as a walk.
        let gate = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 0))
        #expect(gate.decide(sample(3, drifted(4), accuracy: 0)) == .skip)
        #expect(SavedLocationGate.displacementFloor == 10)
    }

    @Test("The displacement rule is symmetric and self-describing")
    func displacementRuleIsPure() {
        let here = sample(0, positionA, accuracy: 8)
        let there = sample(30, positionB, accuracy: 8)
        #expect(SavedLocationGate.isMeaningfulDisplacement(from: here, to: there))
        #expect(SavedLocationGate.isMeaningfulDisplacement(from: there, to: here))
        #expect(!SavedLocationGate.isMeaningfulDisplacement(from: here, to: here))
    }

    // MARK: - Improved accuracy

    @Test("An accuracy that halves and tightens by at least five metres is saved early")
    func improvedAccuracyOverridesTheInterval() {
        let gate = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 60))
        // The photographer has not moved, but GPeX now knows where they are.
        #expect(gate.decide(sample(3, drifted(1), accuracy: 8)) == .save(.improvedAccuracy))
    }

    @Test("Accuracy noise is not an improvement")
    func trivialAccuracyChangesAreCoalesced() {
        // Halved, but only 1.1 m tighter: nothing anyone can see changed.
        let tiny = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 2))
        #expect(tiny.decide(sample(3, drifted(1), accuracy: 0.9)) == .skip)

        // Ten metres tighter, but nowhere near halved: still 790 m of uncertainty.
        let coarse = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 800))
        #expect(coarse.decide(sample(3, drifted(1), accuracy: 790)) == .skip)

        // A worse accuracy is never a reason to save early.
        let good = self.gate(.oneMinute, seeded: sample(0, positionA, accuracy: 8))
        #expect(good.decide(sample(3, drifted(1), accuracy: 400)) == .skip)
    }

    @Test("Both halves of the accuracy rule are required")
    func accuracyRuleNeedsBothConditions() {
        let from = sample(0, positionA, accuracy: 60)
        #expect(SavedLocationGate.isMateriallyBetterAccuracy(from: from, to: sample(3, positionA, accuracy: 8)))
        // Exactly halved and exactly five metres tighter: the boundary is inclusive.
        let boundary = sample(0, positionA, accuracy: 10)
        #expect(SavedLocationGate.isMateriallyBetterAccuracy(from: boundary, to: sample(3, positionA, accuracy: 5)))
        // Halved but only four metres tighter.
        let narrow = sample(0, positionA, accuracy: 8)
        #expect(!SavedLocationGate.isMateriallyBetterAccuracy(from: narrow, to: sample(3, positionA, accuracy: 4)))
    }

    // MARK: - Stationary

    @Test("Core Location saying stationary is saved early, whatever the interval")
    func stationaryOverridesTheInterval() {
        for interval in LocationSaveInterval.allCases {
            let gate = self.gate(interval)
            #expect(gate.decide(sample(2, drifted(1), stationary: true)) == .save(.becameStationary))
        }
    }

    @Test("Once stationary is known, repeating it obeys the interval again")
    func repeatedStationaryDoesNotBypassTheInterval() {
        var gate = SavedLocationGate(interval: .thirtySeconds)
        gate.noteSaved(sample(0, positionA, stationary: true))
        #expect(gate.isStationary)

        // An hour parked in one place must not become an hour of identical rows.
        #expect(gate.decide(sample(5, drifted(1), stationary: true)) == .skip)
        #expect(gate.decide(sample(20, drifted(1), stationary: true)) == .skip)
        // The interval still applies, so the track does not go completely silent either.
        #expect(gate.decide(sample(30, drifted(1), stationary: true)) == .save(.intervalElapsed))
    }

    @Test("The first fix that is no longer stationary is saved early")
    func resumedTrackingIsSavedEarly() {
        var gate = SavedLocationGate(interval: .oneMinute)
        gate.noteSaved(sample(0, positionA, stationary: true))
        // Two seconds later, right where it was: still worth a row, because "no longer
        // stationary" is the thing the interval would otherwise hide for a whole minute.
        #expect(gate.decide(sample(2, drifted(1))) == .save(.resumedAfterStationary))
    }

    @Test("A stationary report with no coordinate still counts as stationary information")
    func stationaryWithoutLocationIsRemembered() {
        var gate = SavedLocationGate(interval: .oneMinute)
        gate.noteSaved(sample(0))
        #expect(!gate.isStationary)

        gate.noteStationaryWithoutLocation()
        #expect(gate.isStationary)
        // Nothing was written, so the interval was not restarted...
        #expect(gate.lastSaved == sample(0))
        // ...but the next ordinary fix is now the first one after a stationary stretch.
        #expect(gate.decide(sample(4, drifted(1))) == .save(.resumedAfterStationary))
    }

    @Test("Resuming is offered once, not on every subsequent fix")
    func resumeFiresOnce() {
        var gate = SavedLocationGate(interval: .oneMinute)
        gate.noteSaved(sample(0, positionA, stationary: true))

        let resumed = sample(2, drifted(1))
        #expect(gate.decide(resumed) == .save(.resumedAfterStationary))
        gate.noteSaved(resumed)
        #expect(!gate.isStationary)
        // Back to ordinary coalescing.
        #expect(gate.decide(sample(6, drifted(1))) == .skip)
    }
}
