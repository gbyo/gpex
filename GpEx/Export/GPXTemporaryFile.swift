import Foundation
import OSLog

/// Writes exported GPX to a temporary file for sharing, and cleans up after itself.
///
/// Exports are never kept in the app container: the directory is emptied at launch and
/// whenever a new export replaces an old one, so a track only persists outside the
/// database if the user actually saved or sent it.
nonisolated enum GPXTemporaryFile {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "GPXExports", directoryHint: .isDirectory)
    }

    /// Writes `xml` to `filename`, replacing any previous export.
    static func write(_ xml: String, filename: String) throws -> URL {
        let directory = directory
        // One export at a time: clearing first prevents renamed sessions from leaving
        // stale files behind.
        purge()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        try Data(xml.utf8).write(to: url, options: .atomic)
        Log.export.info("Wrote export, \(xml.utf8.count, privacy: .public) bytes")
        return url
    }

    /// Removes every temporary export.
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
