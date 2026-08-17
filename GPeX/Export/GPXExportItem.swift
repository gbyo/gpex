import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A finished GPX document, ready to hand to the system.
///
/// This is the *last* step of the export pipeline and does none of its work:
///
/// ```
/// TrackStore → session snapshot + points → GPXExporter → GPX string
///            → GPXExportItem → ShareLink
/// ```
///
/// There is no SwiftData here and no GPX generation here. The bytes and the filename
/// arrive already decided, which is what keeps `GPXExporter` the single deterministic
/// source of both.
nonisolated struct GPXExportItem: Transferable, Sendable, Equatable {
    /// The name `GPXExporter.filename(for:)` chose. Carried through unchanged, because
    /// the date-prefixed name is how a photographer finds the right track later.
    let filename: String
    /// Exactly what `GPXExporter.gpx(session:samples:)` returned.
    let xml: String

    var data: Data { Data(xml.utf8) }

    static var transferRepresentation: some TransferRepresentation {
        // File-based rather than data-based: a `.gpx` is a document. Sharing it as a
        // file is what lets Files, Mail and AirDrop treat it as one, and what makes
        // the filename survive the trip to the Mac.
        FileRepresentation(exportedContentType: .gpx) { item in
            // `allowAccessingOriginalFile` defaults to false, so the system takes its
            // own copy and GPeX's staged file is never handed out directly.
            SentTransferredFile(try GPXTemporaryFile.stage(item.xml, filename: item.filename))
        }
        .suggestedFileName { $0.filename }
    }
}
