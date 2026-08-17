import CoreLocation
import Foundation
import Testing
@testable import GPeX

@Suite("Accuracy handling")
nonisolated struct AccuracyTests {
    private let exporter = GPXExporter()

    @Test("Accuracy buckets follow the documented thresholds")
    func qualityBuckets() {
        #expect(LocationQuality(horizontalAccuracy: 5) == .excellent)
        #expect(LocationQuality(horizontalAccuracy: 10) == .excellent)
        #expect(LocationQuality(horizontalAccuracy: 10.1) == .good)
        #expect(LocationQuality(horizontalAccuracy: 20) == .good)
        #expect(LocationQuality(horizontalAccuracy: 35) == .usable)
        #expect(LocationQuality(horizontalAccuracy: 50) == .usable)
        #expect(LocationQuality(horizontalAccuracy: 51) == .poor)
        #expect(LocationQuality(horizontalAccuracy: -1) == .poor)
    }

    @Test("A negative horizontal accuracy is rejected outright")
    func negativeAccuracyRejected() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
            altitude: 100,
            horizontalAccuracy: -1,
            verticalAccuracy: 3,
            timestamp: testBase
        )
        #expect(LocationSample(location: location, stationary: false) == nil)
    }

    @Test("An accurate fix wins over a poor one in the same second")
    func accurateFixPreferred() throws {
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0.1, (latitude: 41.90000, longitude: -87.60000), accuracy: 80),
                sample(0.6, positionA, accuracy: 4),
            ]
        )
        #expect(points.count == 1)
        #expect(points[0].latitude == positionA.latitude)
    }

    @Test("A stationary report in a collapsed second is not lost")
    func stationaryFlagSurvivesCollapse() throws {
        let points = exporter.plan(
            session: session(),
            samples: [
                sample(0, positionA, accuracy: 40, stationary: true),
                sample(0.5, positionA, accuracy: 6, stationary: false),
                sample(600, positionB),
            ]
        )
        // The better fix is kept, but the stationary observation still drives a bridge.
        #expect(points.contains { $0.origin == .stationaryBridge })
    }

    @Test("Poor fixes are kept rather than discarded")
    func poorFixesRetained() throws {
        // A 60 m fix is worse than nothing only if you throw it away.
        let points = exporter.plan(
            session: session(),
            samples: [sample(0, accuracy: 120), sample(60, positionB, accuracy: 85)]
        )
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.origin == .observed })
    }

    @Test("A session of only poor fixes still exports")
    func onlyPoorFixesStillExports() throws {
        let xml = try exporter.gpx(
            session: session(start: 0, end: 600),
            samples: [sample(0, accuracy: 300), sample(300, positionB, accuracy: 450)]
        )
        #expect(GPXExporter.isWellFormedXML(xml))
        #expect(GPXDocumentTests.times(in: xml).count == 2)
    }

    @Test("Impossible coordinates never reach the file")
    func invalidCoordinatesFiltered() throws {
        let samples = [
            LocationSample(timestamp: testBase, latitude: 200, longitude: 0, horizontalAccuracy: 5),
            LocationSample(timestamp: testBase.addingTimeInterval(10), latitude: 0, longitude: .infinity, horizontalAccuracy: 5),
            sample(20, positionA),
        ]
        let points = exporter.plan(session: session(), samples: samples)
        // The one good fix survives; it also anchors the session start, which is a
        // separate behaviour covered in SessionAnchorTests.
        let observed = points.filter { $0.origin == .observed }
        #expect(observed.count == 1)
        #expect(observed[0].latitude == positionA.latitude)
        #expect(points.allSatisfy { $0.latitude == positionA.latitude })
    }
}

@Suite("Filenames")
nonisolated struct FilenameTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("A session name becomes a readable filename")
    func standardFilename() {
        let name = GPXExporter.filename(
            for: session(name: "Soccer vs Greenwood"),
            timeZone: utc
        )
        #expect(name == "2026-08-17-Soccer-vs-Greenwood.gpx")
    }

    @Test("Unsafe characters are replaced and runs collapse to one dash")
    func sanitizesUnsafeCharacters() {
        #expect(GPXExporter.sanitizedForFilename("Soccer — Aug 17") == "Soccer-Aug-17")
        #expect(GPXExporter.sanitizedForFilename("Field #2 / North") == "Field-2-North")
        #expect(GPXExporter.sanitizedForFilename("a/b\\c:d*e?f\"g<h>i|j") == "a-b-c-d-e-f-g-h-i-j")
        #expect(GPXExporter.sanitizedForFilename("  leading and trailing  ") == "leading-and-trailing")
        #expect(GPXExporter.sanitizedForFilename("under_scores_kept") == "under_scores_kept")
    }

    @Test("A name with nothing usable falls back to the app name")
    func emptyNameFallsBack() {
        #expect(GPXExporter.sanitizedForFilename("///").isEmpty)
        #expect(GPXExporter.sanitizedForFilename("").isEmpty)
        let name = GPXExporter.filename(for: session(name: "///"), timeZone: utc)
        #expect(name == "2026-08-17-GPeX.gpx")
    }

    @Test("Very long names are truncated")
    func longNameTruncated() {
        let long = String(repeating: "Greenwood", count: 40)
        let sanitized = GPXExporter.sanitizedForFilename(long)
        #expect(sanitized.count <= 60)
    }

    @Test("The extension is always .gpx")
    func extensionIsGPX() {
        #expect(GPXExporter.filename(for: session(name: "x.txt"), timeZone: utc).hasSuffix(".gpx"))
    }

    @Test("The date comes from the session's local start day")
    func dateUsesLocalStartDay() {
        // 02:00 UTC on 18 August is still the evening of 17 August in Chicago.
        let late = session(name: "Night Game", start: 50_400, base: testBase)
        #expect(GPXExporter.filename(for: late, timeZone: utc) == "2026-08-18-Night-Game.gpx")
        let chicago = TimeZone(identifier: "America/Chicago")!
        #expect(GPXExporter.filename(for: late, timeZone: chicago) == "2026-08-17-Night-Game.gpx")
    }
}
