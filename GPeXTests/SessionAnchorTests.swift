import Foundation
import Testing
@testable import GPeX

@Suite("Session start and end anchors")
nonisolated struct SessionAnchorTests {
    private let exporter = GPXExporter()

    // MARK: - Start

    @Test("A prompt first fix covers the session start")
    func promptFirstFixCoversStart() throws {
        // Photographs taken in the eight seconds between Start and the first fix still
        // need a position.
        let points = exporter.plan(
            session: session(start: 0, end: 600),
            samples: [sample(8, positionA), sample(60, positionA, stationary: true)]
        )
        let first = try #require(points.first)
        #expect(first.origin == .sessionStartAnchor)
        #expect(first.offsetFromBase == 0)
        #expect(first.latitude == positionA.latitude)
    }

    @Test("A first fix minutes later is not backdated to the start")
    func lateFirstFixIsNotBackdated() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 900),
            samples: [sample(420, positionA), sample(480, positionA)]
        )
        #expect(!points.contains { $0.origin == .sessionStartAnchor })
        #expect(try #require(points.first).offsetFromBase == 420)
    }

    @Test("A first fix taken while walking is not projected back to the start")
    func movingFirstFixIsNotBackdated() throws {
        // If they were already walking when the fix arrived, they were not standing at
        // that coordinate when they tapped Start.
        let points = exporter.plan(
            session: session(start: 0, end: 600),
            samples: [sample(10, positionA, speed: 2.5), sample(60, positionB)]
        )
        #expect(!points.contains { $0.origin == .sessionStartAnchor })
    }

    @Test("A slow-walking-speed fix still counts as standing still")
    func slowFixStillAnchorsStart() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 600),
            samples: [sample(10, positionA, speed: 0.2), sample(60, positionA)]
        )
        #expect(points.first?.origin == .sessionStartAnchor)
    }

    @Test("The start anchor is dropped when it lands in the first fix's own second")
    func startAnchorDoesNotDuplicateFirstFix() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 600),
            samples: [sample(0.4, positionA), sample(60, positionA)]
        )
        // Both would be written as 12:00:00; the real observation wins.
        #expect(points.filter { $0.offsetFromBase == 0 }.count == 1)
        #expect(points.first?.origin == .observed)
    }

    // MARK: - End

    @Test("A final stationary position extends to the session end")
    func stationaryEndExtendsToEnd() throws {
        // The photographer stood at B for the last twenty minutes of the game.
        let points = exporter.plan(
            session: session(start: 0, end: 1_800),
            samples: [sample(0, positionA), sample(600, positionB, stationary: true)]
        )
        let last = try #require(points.last)
        #expect(last.origin == .sessionEndAnchor)
        #expect(last.offsetFromBase == 1_800)
        #expect(last.latitude == positionB.latitude)
    }

    @Test("A stale fix taken while moving is not fabricated as the final position")
    func staleMovingEndIsNotFabricated() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 1_800),
            samples: [sample(0, positionA), sample(600, positionB, speed: 1.8)]
        )
        #expect(!points.contains { $0.origin == .sessionEndAnchor })
        #expect(try #require(points.last).offsetFromBase == 600)
    }

    @Test("A fresh fix taken while moving does cover the session end")
    func freshMovingEndCoversEnd() throws {
        let points = exporter.plan(
            session: session(start: 0, end: 610),
            samples: [sample(0, positionA), sample(600, positionB, speed: 1.8)]
        )
        let last = try #require(points.last)
        #expect(last.origin == .sessionEndAnchor)
        #expect(last.offsetFromBase == 610)
    }

    @Test("An unfinished session gets no end anchor")
    func unfinishedSessionHasNoEndAnchor() throws {
        let points = exporter.plan(
            session: session(start: 0, end: nil),
            samples: [sample(0, positionA), sample(600, positionA, stationary: true)]
        )
        #expect(!points.contains { $0.origin == .sessionEndAnchor })
    }

    @Test("Start and end anchors coexist with a stationary bridge")
    func fullSessionShape() throws {
        // A whole game: acquire, stand at A, move to B, stand at B, stop.
        let points = exporter.plan(
            session: session(start: 0, end: 3_600),
            samples: [
                sample(6, positionA),
                sample(30, positionA, stationary: true),
                sample(1_800, positionB),
                sample(1_830, positionB, stationary: true),
            ]
        )
        #expect(points.map(\.origin) == [
            .sessionStartAnchor,
            .observed,
            .observed,
            .stationaryBridge,
            .observed,
            .observed,
            .sessionEndAnchor,
        ])
        #expect(points.map(\.offsetFromBase) == [0, 6, 30, 1_799, 1_800, 1_830, 3_600])
        // Strictly increasing, as Lightroom requires.
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
    }
}
