#if canImport(StateReporting)
import Foundation
import OSLog
import StateReporting

/// Reports the recording phase to the system on iOS 27 and later.
///
/// This is a *description* of state that already exists, never a second copy of it.
/// Nothing here decides anything: it is handed a phase by the one place in
/// `RecordingCoordinator` that changes state, maps it to a fixed label, and hands
/// that to `StateReporter`.
///
/// No metadata is attached. A session ID, coordinate, filename or accuracy value
/// would make every recording its own state, which is both a privacy problem and
/// the thing that makes aggregated reports useless.
@available(iOS 27, *)
struct StateReportingRecordingReporter: RecordingPerformanceReporting {
    /// `StateReporter.reporter(for:)` returns the same object for a given domain, so
    /// holding one here does not create a second reporter for the process.
    private let reporter: StateReporter<Never, Never>

    /// Guards against redundant calls. `SRStateReporter` already treats an unchanged
    /// label as a no-op, and it rate-limits callers that report too often, so the
    /// cheapest thing to do with a repeat is not to make the call at all.
    private let lastLabel = LastReportedLabel()

    init(domain: String) {
        reporter = StateReporter.reporter(for: domain)
    }

    func transition(to phase: RecordingPhase) {
        let label = phase.performanceStateLabel
        guard lastLabel.update(to: label) else { return }
        reporter.reportTransition(to: label)
        Log.metrics.debug("Recording state \(label ?? "cleared", privacy: .public)")
    }

    /// A tiny box so the reporter can stay a `struct` while remembering one string.
    private final class LastReportedLabel: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String??

        /// Returns `true` when the label actually changed.
        func update(to label: String?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let value, value == label { return false }
            value = label
            return true
        }
    }
}
#endif
