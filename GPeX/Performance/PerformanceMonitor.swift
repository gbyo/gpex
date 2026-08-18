import Foundation
import MetricKit
import OSLog

/// What the two MetricKit generations hand their reports to.
///
/// A seam, so the iOS 26 and iOS 27 paths converge on one implementation of "log a
/// summary and keep a bounded copy" instead of each growing their own.
nonisolated protocol PerformanceReportHandling: Sendable {
    func handleMetricReport(summary: String, json: Data?)
    func handleDiagnosticReport(summary: String, json: Data?)
}

/// GPeX's one performance-monitoring service, for the life of the process.
///
/// It observes; it never acts. Nothing here can influence a recording, and nothing in
/// recording waits on it — `start()` is called once at launch, everything it does
/// afterwards happens on detached tasks, and every failure is swallowed with a log
/// line. There is no networking, no analytics and no upload of any kind: reports are
/// summarised to `Log.metrics` and, at most, a handful are kept in Caches for a
/// developer with the device in their hand.
///
/// Exactly one instance exists, held by `AppServices`, and `start()` is idempotent —
/// the iOS 27 API requires a single `MetricManager` per process, and the iOS 26 API
/// would deliver every payload once per subscription.
final class PerformanceMonitor {
    private let handler: PerformanceReportRecorder

    private var isStarted = false

    /// Retained for the life of the process, which is the life of the service. There
    /// is deliberately no `stop()`: a monitor that could be torn down and restarted
    /// would be a second chance to create a second `MetricManager`, and nothing in
    /// GPeX has any reason to stop observing.
    private var tasks: [Task<Void, Never>] = []

    /// The single `MetricManager` for the process on iOS 27. Held as `AnyObject` so
    /// this type does not need an availability annotation of its own.
    private var metricManager: AnyObject?

    private var legacyReceiver: AnyObject?

    init(archive: PerformanceReportArchive = PerformanceReportArchive()) {
        self.handler = PerformanceReportRecorder(archive: archive)
    }

    /// Begins observing. Safe to call more than once; only the first call does work.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        if #available(iOS 27, *) {
            startModern()
        } else {
            startLegacy()
        }
    }

    // MARK: - iOS 27

    @available(iOS 27, *)
    private func startModern() {
        // Enabling the recording domain is what makes GPeX's own state labels show up
        // in metric reports, so hangs and terminations can be attributed to what the
        // app was doing rather than to the app as a whole.
        let manager = MetricManager(
            enabledStateReportingDomains: [
                StateReportingDomain(rawValue: RecordingPerformanceDomain.identifier)
            ]
        )
        metricManager = manager

        let handler = handler
        tasks = [
            Task.detached(priority: .utility) {
                for await report in manager.metricReports {
                    handler.handle(metricReport: report)
                }
            },
            Task.detached(priority: .utility) {
                for await report in manager.diagnosticReports {
                    handler.handle(diagnosticReport: report)
                }
            },
        ]
        Log.metrics.info("Observing MetricManager reports")
    }

    // MARK: - iOS 26

    private func startLegacy() {
        let receiver = LegacyMetricKitReceiver(handler: handler)
        legacyReceiver = receiver
        receiver.subscribe()
    }
}

/// Logs a concise summary and keeps a bounded local copy. The only thing that ever
/// happens to a report.
nonisolated private struct PerformanceReportRecorder: PerformanceReportHandling {
    let archive: PerformanceReportArchive

    /// Sequence numbers so archived files sort in arrival order without a timestamp.
    private let sequence = Counter()

    func handleMetricReport(summary: String, json: Data?) {
        Log.metrics.notice("Metrics: \(summary, privacy: .public)")
        archiveIfPresent(json, kind: .metric)
    }

    func handleDiagnosticReport(summary: String, json: Data?) {
        Log.metrics.notice("Diagnostics: \(summary, privacy: .public)")
        archiveIfPresent(json, kind: .diagnostic)
    }

    private func archiveIfPresent(_ json: Data?, kind: PerformanceReportArchive.Kind) {
        guard let json else { return }
        archive.store(json, kind: kind, sequence: sequence.next())
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

// MARK: - iOS 27 report summaries

@available(iOS 27, *)
nonisolated extension PerformanceReportRecorder {
    /// Counts and durations only.
    ///
    /// `ReportedState.label` is one of GPeX's own fixed labels, which is why it is
    /// safe to log: there is no session name, coordinate or identifier in it.
    func handle(metricReport report: MetricReport) {
        let states = report.stateEntries.map(\.state.label).sorted()
        let summary = """
        \(report.stateEntries.count) state entries, \(report.intervalEntries.count) interval entries, \
        states [\(states.joined(separator: " "))]
        """
        handleMetricReport(summary: summary, json: try? JSONEncoder().encode(report))
    }

    func handle(diagnosticReport report: DiagnosticReport) {
        handleDiagnosticReport(
            summary: Self.label(for: report.result),
            json: try? JSONEncoder().encode(report)
        )
    }

    /// The kind of diagnostic, and nothing else. No call stacks, no binary names, no
    /// termination text — those go in the archived JSON, which never leaves the device.
    private static func label(for result: DiagnosticResult) -> String {
        switch result {
        case .crash: "crash"
        case .hang: "hang"
        case .cpuException: "cpuException"
        case .diskWriteException: "diskWriteException"
        case .appLaunch: "appLaunch"
        case .memoryException: "memoryException"
        @unknown default: "unknown"
        }
    }
}
