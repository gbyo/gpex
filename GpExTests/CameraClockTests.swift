import Foundation
import Testing
@testable import GpEx

@Suite("Camera clock correction")
nonisolated struct CameraClockTests {
    private let exporter = GPXExporter()

    @Test("A slow camera shifts exported timestamps earlier")
    func negativeCorrection() throws {
        // Camera is 5 s slow, so a fix at 11:07:42 must be written as 11:07:37 for the
        // camera's own timestamp to match.
        let xml = try exporter.gpx(
            session: session(offsetSeconds: -5),
            samples: [sample(0)]
        )
        #expect(xml.contains("<time>2026-08-17T11:59:55Z</time>"))
    }

    @Test("A fast camera shifts exported timestamps later")
    func positiveCorrection() throws {
        // Camera is 90 s fast.
        let xml = try exporter.gpx(
            session: session(offsetSeconds: 90),
            samples: [sample(0)]
        )
        #expect(xml.contains("<time>2026-08-17T12:01:30Z</time>"))
    }

    @Test("Corrections work at second resolution, not just whole minutes")
    func secondLevelCorrection() throws {
        let xml = try exporter.gpx(session: session(offsetSeconds: -7), samples: [sample(0)])
        #expect(xml.contains("<time>2026-08-17T11:59:53Z</time>"))
    }

    @Test("No correction leaves timestamps untouched")
    func zeroCorrection() throws {
        let xml = try exporter.gpx(session: session(offsetSeconds: 0), samples: [sample(0)])
        #expect(xml.contains("<time>2026-08-17T12:00:00Z</time>"))
    }

    @Test("The correction applies to every point uniformly")
    func correctionAppliesToAllPoints() throws {
        let points = exporter.plan(
            session: session(offsetSeconds: 3_600),
            samples: [sample(0), sample(60, positionB), sample(120, positionC)]
        )
        #expect(points.map(\.offsetFromBase) == [3_600, 3_660, 3_720])
    }

    @Test("Session anchors move with the correction too")
    func correctionShiftsAnchors() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 600, offsetSeconds: 30),
            samples: [sample(5, positionA), sample(60, positionA, stationary: true)]
        )
        // The start anchor lands at the corrected start time, not the raw one.
        #expect(points.first?.origin == .sessionStartAnchor)
        #expect(points.first?.offsetFromBase == 30)
        #expect(points.last?.origin == .sessionEndAnchor)
        #expect(points.last?.offsetFromBase == 630)
    }

    // MARK: - Sign handling in the UI type

    @Test("Slow means a negative offset, fast means positive")
    func directionSigns() {
        #expect(ClockCorrection(direction: .slow, seconds: 5).offsetSeconds == -5)
        #expect(ClockCorrection(direction: .fast, minutes: 1, seconds: 30).offsetSeconds == 90)
        #expect(ClockCorrection.none.offsetSeconds == 0)
    }

    @Test("A stored offset decomposes back to the same correction")
    func roundTrip() {
        for offset in [-5.0, 90.0, 0.0, -3_725.0, 45.0] {
            let correction = ClockCorrection(offsetSeconds: offset)
            #expect(correction.offsetSeconds == offset)
        }
    }

    @Test("The sign shown to the user is unambiguous")
    func signedAdjustmentText() {
        #expect(ClockCorrection(direction: .slow, seconds: 5).signedAdjustment == "−00:00:05")
        #expect(ClockCorrection(direction: .fast, minutes: 1, seconds: 30).signedAdjustment == "+00:01:30")
        #expect(ClockCorrection(direction: .fast, hours: 2).signedAdjustment == "+02:00:00")
        #expect(ClockCorrection.none.signedAdjustment == "00:00:00")
    }

    @Test("The correction summary reads as a sentence")
    func summaryText() {
        #expect(ClockCorrection.none.summary == "None")
        #expect(ClockCorrection(direction: .slow, seconds: 5).summary == "Camera was 5 seconds slow")
        #expect(ClockCorrection(direction: .fast, minutes: 2).summary == "Camera was 2 minutes fast")
    }

    @Test("VoiceOver hears the direction spelled out rather than a minus sign")
    func spokenAdjustment() {
        #expect(ClockCorrection(direction: .slow, seconds: 5).spokenAdjustment.contains("earlier"))
        #expect(ClockCorrection(direction: .fast, seconds: 5).spokenAdjustment.contains("later"))
        #expect(ClockCorrection.none.spokenAdjustment == "No adjustment")
    }
}
