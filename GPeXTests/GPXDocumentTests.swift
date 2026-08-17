import Foundation
import Testing
@testable import GPeX

@Suite("GPX document")
nonisolated struct GPXDocumentTests {
    private let exporter = GPXExporter()

    @Test("Produces a valid GPX 1.1 document")
    func validStructure() throws {
        let xml = try exporter.gpx(
            session: session(name: "Soccer", end: 60),
            samples: [sample(0), sample(30, positionB)]
        )

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<gpx version=\"1.1\""))
        #expect(xml.contains("creator=\"GPeX\""))
        #expect(xml.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        #expect(xml.contains("<trk>"))
        #expect(xml.contains("<name>Soccer</name>"))
        #expect(xml.contains("<trkseg>"))
        #expect(xml.contains("</trkseg>"))
        #expect(xml.contains("</gpx>"))
        #expect(GPXExporter.isWellFormedXML(xml))
    }

    @Test("Track points appear in chronological order")
    func chronologicalOrder() throws {
        // Deliberately out of order on the way in.
        let xml = try exporter.gpx(
            session: session(),
            samples: [sample(120, positionC), sample(0), sample(60, positionB)]
        )
        let times = Self.times(in: xml)
        #expect(times == times.sorted())
        #expect(times == ["2026-08-17T12:00:00Z", "2026-08-17T12:01:00Z", "2026-08-17T12:02:00Z"])
    }

    @Test("Timestamps are UTC ISO 8601")
    func utcTimestamps() throws {
        let xml = try exporter.gpx(session: session(), samples: [sample(3721)])
        // 12:00:00Z + 1h 2m 1s
        #expect(xml.contains("<time>2026-08-17T13:02:01Z</time>"))
        #expect(!xml.contains("+00:00"))
    }

    @Test("Coordinates use a decimal point regardless of locale")
    func localeIndependentDecimals() throws {
        let xml = try exporter.gpx(session: session(), samples: [sample(0)])
        #expect(xml.contains("lat=\"41.8781000\""))
        #expect(xml.contains("lon=\"-87.6298000\""))
        // A comma decimal separator would make the file unreadable.
        let pointLine = try #require(xml.split(separator: "\n").first { $0.contains("<trkpt") })
        #expect(!pointLine.contains(","))
    }

    @Test("Coordinates keep enough precision to place a photographer on a field")
    func coordinatePrecision() throws {
        let xml = try exporter.gpx(
            session: session(),
            samples: [sample(0, (latitude: 41.87811234567, longitude: -87.62981234567))]
        )
        #expect(xml.contains("lat=\"41.8781123\""))
        #expect(xml.contains("lon=\"-87.6298123\""))
    }

    @Test("Session names are XML-escaped")
    func escapesNames() throws {
        let xml = try exporter.gpx(
            session: session(name: #"Us & "Them" <3 it's >here"#),
            samples: [sample(0)]
        )
        #expect(xml.contains("<name>Us &amp; &quot;Them&quot; &lt;3 it&apos;s &gt;here</name>"))
        #expect(GPXExporter.isWellFormedXML(xml))
    }

    @Test("Valid altitude is exported as an elevation")
    func includesValidAltitude() throws {
        let xml = try exporter.gpx(
            session: session(),
            samples: [sample(0, altitude: 181.44, verticalAccuracy: 3)]
        )
        #expect(xml.contains("<ele>181.4</ele>"))
    }

    @Test("Missing altitude omits the elevation element entirely")
    func omitsInvalidAltitude() throws {
        let xml = try exporter.gpx(session: session(), samples: [sample(0, altitude: nil)])
        #expect(!xml.contains("<ele>"))
        #expect(GPXExporter.isWellFormedXML(xml))
    }

    @Test("Elevation precedes time, as the GPX 1.1 schema requires")
    func elementOrder() throws {
        let xml = try exporter.gpx(
            session: session(),
            samples: [sample(0, altitude: 100, verticalAccuracy: 3)]
        )
        let elevationIndex = try #require(xml.range(of: "<ele>")).lowerBound
        let timeIndex = try #require(xml.range(of: "<time>")).lowerBound
        #expect(elevationIndex < timeIndex)
    }

    @Test("Timestamps never repeat or go backwards")
    func strictlyIncreasingTimestamps() throws {
        // Two fixes inside the same second, plus an out-of-order duplicate.
        let samples = [
            sample(0, accuracy: 30),
            sample(0.4, accuracy: 5),
            sample(1),
            sample(1.9, accuracy: 12),
            sample(0.9, accuracy: 40),
        ]
        let xml = try exporter.gpx(session: session(), samples: samples)
        let times = Self.times(in: xml)
        #expect(times == Array(Set(times)).sorted())
        #expect(times.count == 2)
    }

    @Test("An empty session cannot produce a misleading file")
    func emptySessionThrows() {
        #expect(throws: GPXExportError.noUsableLocations) {
            _ = try exporter.gpx(session: session(), samples: [])
        }
    }

    @Test("A session of only unusable fixes cannot produce a file")
    func onlyInvalidFixesThrows() {
        let broken = [
            LocationSample(timestamp: testBase, latitude: .nan, longitude: 0, horizontalAccuracy: 5),
            LocationSample(timestamp: testBase, latitude: 0, longitude: 0, horizontalAccuracy: -1),
        ]
        #expect(throws: GPXExportError.noUsableLocations) {
            _ = try exporter.gpx(session: session(), samples: broken)
        }
    }

    /// Extracts the text of every `<time>` element.
    static func times(in xml: String) -> [String] {
        xml.split(separator: "\n").compactMap { line in
            guard let open = line.range(of: "<time>"), let close = line.range(of: "</time>") else {
                return nil
            }
            return String(line[open.upperBound..<close.lowerBound])
        }
    }
}
