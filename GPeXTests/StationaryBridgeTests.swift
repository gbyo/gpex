import Foundation
import Testing
@testable import GPeX

@Suite("Stationary bridge")
nonisolated struct StationaryBridgeTests {
    private let exporter = GPXExporter()

    /// The behaviour the whole app exists for.
    ///
    /// A photographer stands at A from 12:00 to 12:10 and then walks to B. Core
    /// Location stops delivering while they stand still, so the raw data is three
    /// points. Anything that interpolates between the 12:00:10 fix and the 12:10:00 fix
    /// will believe they spent ten minutes drifting across the field.
    @Test("A stationary gap becomes a step, not a ten-minute drift")
    func stationaryGapIsNotInterpolated() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 600),
            samples: [
                sample(0, positionA),
                sample(10, positionA, stationary: true),
                sample(600, positionB),
            ]
        )

        #expect(points.map(\.offsetFromBase) == [0, 10, 599, 600])
        #expect(points.map(\.origin) == [.observed, .observed, .stationaryBridge, .observed])

        // The bridge holds A, so the move to B happens in the final second.
        let bridge = points[2]
        #expect(bridge.latitude == positionA.latitude)
        #expect(bridge.longitude == positionA.longitude)

        // Nothing between the stationary fix and the bridge, and no invented position
        // anywhere between A and B.
        let betweenGap = points.filter { $0.offsetFromBase > 10 && $0.offsetFromBase < 599 }
        #expect(betweenGap.isEmpty)
        let latitudes = Set(points.map(\.latitude))
        #expect(latitudes == [positionA.latitude, positionB.latitude])
    }

    @Test("The bridge never precedes the stationary anchor it holds")
    func bridgeStaysAfterAnchor() throws {
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, positionA, stationary: true),
                sample(3_600, positionB),
            ]
        )
        let anchorTime = try #require(points.first).offsetFromBase
        let bridge = try #require(points.first { $0.origin == .stationaryBridge })
        #expect(bridge.offsetFromBase > anchorTime)
        #expect(bridge.offsetFromBase == 3_599)
    }

    @Test("Each stationary period gets its own bridge")
    func multipleStationaryPeriods() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 1_200),
            samples: [
                sample(0, positionA),
                sample(10, positionA, stationary: true),
                sample(600, positionB),
                sample(610, positionB, stationary: true),
                sample(1_200, positionC),
            ]
        )

        let bridges = points.filter { $0.origin == .stationaryBridge }
        #expect(bridges.count == 2)
        #expect(bridges[0].offsetFromBase == 599)
        #expect(bridges[0].latitude == positionA.latitude)
        #expect(bridges[1].offsetFromBase == 1_199)
        #expect(bridges[1].latitude == positionB.latitude)

        #expect(points.map(\.offsetFromBase) == [0, 10, 599, 600, 610, 1_199, 1_200])
    }

    @Test("A one-second stationary interval gets no bridge")
    func shortGapIsLeftAlone() throws {
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, positionA),
                sample(10, positionA, stationary: true),
                sample(11, positionB),
            ]
        )
        #expect(points.allSatisfy { $0.origin == .observed })
        #expect(points.map(\.offsetFromBase) == [0, 10, 11])
    }

    @Test("A gap with no stationary report is preserved, not bridged")
    func gapWithoutStationaryIsPreserved() throws {
        // Twelve minutes of silence with no stationary flag could be a tunnel or a
        // dropped fix. Guessing the photographer stood still would be inventing data.
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, positionA),
                sample(10, positionA),
                sample(720, positionB),
            ]
        )
        #expect(points.allSatisfy { $0.origin == .observed })
        #expect(points.count == 3)
    }

    @Test("Standing still without moving away needs no bridge")
    func noBridgeWhenBarelyMoved() throws {
        // The resumed fix is metres from the anchor, so interpolating across the gap
        // cannot mislead anyone and a bridge would only add a redundant point.
        let nearby = (latitude: positionA.latitude + 0.00002, longitude: positionA.longitude)
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, positionA, stationary: true),
                sample(600, nearby),
            ]
        )
        #expect(points.allSatisfy { $0.origin == .observed })
    }

    @Test("The bridge holds the most accurate recent fix, not a noisy one")
    func bridgePrefersTheMostAccurateAnchor() throws {
        let accurate = (latitude: 41.87810, longitude: -87.62980)
        let noisy = (latitude: 41.87840, longitude: -87.62930)
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, accurate, accuracy: 4),
                sample(20, noisy, accuracy: 65, stationary: true),
                sample(600, positionB),
            ]
        )

        let bridge = try #require(points.first { $0.origin == .stationaryBridge })
        // The 4 m fix 20 s earlier describes where they stood far better than the 65 m
        // one, and averaging the two would invent a position that was never observed.
        #expect(bridge.latitude == accurate.latitude)
        #expect(bridge.longitude == accurate.longitude)

        // The noisy observation itself is still exported untouched.
        let observed = points.filter { $0.origin == .observed }
        #expect(observed.contains { $0.latitude == noisy.latitude })
    }

    @Test("The anchor search does not reach back beyond its window")
    func anchorWindowIsBounded() throws {
        let veryOldAndAccurate = (latitude: 41.90000, longitude: -87.60000)
        let points = exporter.plan(
            session: session(),
            samples: [
                // 120 s before the transition: outside the 30 s window, however good.
                sample(0, veryOldAndAccurate, accuracy: 1),
                sample(120, positionA, accuracy: 25, stationary: true),
                sample(600, positionB),
            ]
        )
        let bridge = try #require(points.first { $0.origin == .stationaryBridge })
        #expect(bridge.latitude == positionA.latitude)
    }

    @Test("Bridges survive a camera clock correction")
    func bridgeWithClockCorrection() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 600, offsetSeconds: -5),
            samples: [
                sample(0, positionA),
                sample(10, positionA, stationary: true),
                sample(600, positionB),
            ]
        )
        // Everything, including the synthetic bridge, shifts with the correction.
        #expect(points.map(\.offsetFromBase) == [-5, 5, 594, 595])
        #expect(points.map(\.origin) == [.observed, .observed, .stationaryBridge, .observed])
    }
}
