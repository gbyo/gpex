import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GPeX

@Suite("GPX transferable export")
nonisolated struct GPXTransferableTests {
    private let exporter = GPXExporter()

    // MARK: - The type

    @Test("The GPX type is the shared identifier, not a GPeX-specific one")
    func utTypeIdentifier() {
        #expect(UTType.gpx.identifier == "com.topografix.gpx")
        #expect(UTType.gpx.conforms(to: .xml))
        #expect(UTType.gpx.preferredFilenameExtension == "gpx")
    }

    @Test("The export item advertises GPX")
    func exportedContentTypes() {
        #expect(GPXExportItem.exportedContentTypes().contains(.gpx))
    }

    // MARK: - The file

    @Test("The filename GPXExporter chose is the filename that is transferred")
    func preservesFilename() throws {
        let snapshot = session(name: "Soccer vs Greenwood")
        let item = GPXExportItem(
            filename: GPXExporter.filename(for: snapshot),
            xml: try exporter.gpx(session: snapshot, samples: [sample(0)])
        )

        #expect(item.filename.hasSuffix(".gpx"))
        #expect(item.filename == GPXExporter.filename(for: snapshot))
        #expect(item.suggestedFilename == item.filename)
    }

    @Test("The transferred file is byte-for-byte what GPXExporter produced")
    func transferredContentsMatchExporter() async throws {
        let snapshot = session(name: "Soccer", end: 120)
        let samples = [sample(0), sample(45, positionB), sample(90, positionC)]
        let xml = try exporter.gpx(session: snapshot, samples: samples)

        let item = GPXExportItem(filename: GPXExporter.filename(for: snapshot), xml: xml)
        let transferred = try await item.exported(as: .gpx)

        #expect(transferred == Data(xml.utf8))
        #expect(String(decoding: transferred, as: UTF8.self) == xml)
    }

    @Test("The staged file carries the exact filename and contents")
    func stagedFileIsCorrect() async throws {
        let snapshot = session(name: "Soccer vs Greenwood")
        let xml = try exporter.gpx(session: snapshot, samples: [sample(0), sample(30, positionB)])
        let item = GPXExportItem(filename: GPXExporter.filename(for: snapshot), xml: xml)

        let (name, contents) = try await item.withExportedFile(contentType: .gpx) { url in
            (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        }

        #expect(name == item.filename)
        #expect(contents == xml)
    }

    // MARK: - The pipeline is unchanged

    @Test("Camera clock correction still reaches the transferred bytes")
    func clockCorrectionSurvivesTransfer() async throws {
        // 90 seconds fast: exported timestamps move forward by 90, positions do not.
        let snapshot = session(name: "Corrected", end: 60, offsetSeconds: 90)
        let xml = try exporter.gpx(session: snapshot, samples: [sample(0), sample(30, positionB)])
        let item = GPXExportItem(filename: GPXExporter.filename(for: snapshot), xml: xml)

        let transferred = String(decoding: try await item.exported(as: .gpx), as: UTF8.self)

        #expect(transferred == xml)
        #expect(transferred.contains("<time>2026-08-17T12:01:30Z</time>"))
        #expect(transferred.contains("<time>2026-08-17T12:02:00Z</time>"))
        #expect(!transferred.contains("<time>2026-08-17T12:00:00Z</time>"))
    }

    @Test("Stationary bridge points still reach the transferred bytes")
    func stationaryBridgeSurvivesTransfer() async throws {
        // Standing at A, then a long gap, then a fix at C: the exporter holds A until
        // one second before the resumed fix rather than letting a reader interpolate.
        let snapshot = session(name: "Bridged")
        let samples = [
            sample(0, positionA, stationary: true),
            sample(600, positionC),
        ]
        let xml = try exporter.gpx(session: snapshot, samples: samples)
        let item = GPXExportItem(filename: GPXExporter.filename(for: snapshot), xml: xml)

        let transferred = String(decoding: try await item.exported(as: .gpx), as: UTF8.self)

        #expect(transferred == xml)
        // The bridge is present, at A's coordinate, one second before the resumed fix.
        #expect(transferred.contains("<time>2026-08-17T12:09:59Z</time>"))
        let bridged = exporter.plan(session: snapshot, samples: samples)
        #expect(bridged.contains { $0.origin == .stationaryBridge })
    }

    @Test("The item is only a carrier: it never regenerates the document")
    func itemDoesNotTransformTheDocument() async throws {
        // Deliberately not something GPXExporter would produce. If the item generated
        // anything of its own, this would not survive.
        let item = GPXExportItem(filename: "fixture.gpx", xml: "<gpx/>\n")
        let transferred = try await item.exported(as: .gpx)
        #expect(String(decoding: transferred, as: UTF8.self) == "<gpx/>\n")
    }
}
