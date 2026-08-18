import Foundation
import OSLog

/// A small, bounded, local-only archive of recent MetricKit reports.
///
/// This exists so a developer can look at yesterday's reports on a device they are
/// holding. Nothing is uploaded, and nothing outside this file ever reads it.
///
/// It lives in Caches because it is disposable by definition: the system may delete
/// it under storage pressure, and losing it costs nothing. Retention is capped by
/// count, so the archive cannot grow without bound on a device that is used daily.
///
/// Reports contain call stacks, OS versions and aggregate timings. They contain no
/// coordinates and no session names, and nothing in GPeX adds any — the state labels
/// MetricKit sees are the fixed vocabulary in `RecordingPhase.performanceStateLabel`.
nonisolated struct PerformanceReportArchive: Sendable {
    /// How many files of each kind to keep. Small on purpose: this is an inspection
    /// aid, not a data store.
    static let retainedReportCount = 5

    enum Kind: String, Sendable {
        case metric
        case diagnostic
    }

    private let directory: URL?

    init(directory: URL? = Self.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "PerformanceReports", directoryHint: .isDirectory)
    }

    /// Writes one report and prunes the oldest. Never throws: an archive that cannot
    /// be written is not a reason for anything else to change behaviour.
    func store(_ data: Data, kind: Kind, sequence: Int) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The sequence number keeps files ordered without a timestamp, so the
            // archive is deterministic and testable.
            let url = directory.appending(
                path: "\(kind.rawValue)-\(String(format: "%06d", sequence)).json",
                directoryHint: .notDirectory
            )
            try data.write(to: url, options: .atomic)
            prune(kind: kind)
        } catch {
            Log.metrics.error("Could not archive \(kind.rawValue, privacy: .public) report: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Files of one kind, oldest first.
    func storedReports(kind: Kind) -> [URL] {
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("\(kind.rawValue)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune(kind: Kind) {
        let stored = storedReports(kind: kind)
        guard stored.count > Self.retainedReportCount else { return }
        for url in stored.prefix(stored.count - Self.retainedReportCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
