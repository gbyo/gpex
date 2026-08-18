import Foundation
import OSLog

/// Staging for the bytes `GPXExportItem` hands to the system.
///
/// A `FileRepresentation` needs a file, so one still has to exist for the moment a
/// share is in flight — but it is no longer part of the app's outward-facing export
/// flow. Nothing outside `GPXExportItem` writes here, no view holds a URL, and the
/// file is only created at the instant the user actually shares something rather than
/// speculatively when a session is opened.
///
/// Exports never outlive the process: the directory is emptied at launch and when a
/// session is deleted, so a track only persists outside the database if the user
/// really saved or sent it.
nonisolated enum GPXTemporaryFile {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "GPXExports", directoryHint: .isDirectory)
    }

    /// Writes `xml` where the system can copy it from, under the exact `filename`.
    ///
    /// Each staged export gets its own subdirectory so two shares of the same session
    /// cannot overwrite each other's file while either is still being copied, and so
    /// the user-visible filename stays untouched by any uniquing.
    static func stage(_ xml: String, filename: String) throws -> URL {
        let container = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let url = container.appending(path: filename, directoryHint: .notDirectory)
        try Data(xml.utf8).write(to: url, options: .atomic)
        Log.export.info("Staged export, \(xml.utf8.count, privacy: .public) bytes")
        return url
    }

    /// Removes every staged export.
    static func purge() {
        let directory = directory
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Log.export.error("Could not purge exports: \(error.localizedDescription, privacy: .public)")
        }
    }
}
