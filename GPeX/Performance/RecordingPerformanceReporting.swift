import Foundation

/// The seam between the recording state machine and the system's performance-state
/// reporting.
///
/// `RecordingCoordinator` owns the recording state; this protocol only lets it
/// *describe* that state to the system. It is deliberately non-throwing and returns
/// nothing: there is no result a recording could act on, and no failure it should
/// react to. Implementations swallow their own problems.
protocol RecordingPerformanceReporting {
    /// Called once per real phase transition, from one place in the coordinator.
    func transition(to phase: RecordingPhase)
}

/// The fixed vocabulary reported to the system.
///
/// Deliberately small and stable. These strings appear in MetricKit reports as state
/// labels, so they are chosen once and then left alone; they carry no session
/// identifier, coordinate, filename, accuracy or any other per-recording detail.
extension RecordingPhase {
    /// The state label for this phase, or `nil` when no state is active.
    ///
    /// `nil` is not "unknown" — it is the explicit instruction to clear the state,
    /// which is what idle means.
    var performanceStateLabel: String? {
        switch self {
        case .idle: nil
        case .waitingForAuthorization: "authorization"
        case .acquiringLocation: "acquiring"
        case .tracking: "tracking"
        case .stationary: "stationary"
        case .temporarilyUnavailable: "unavailable"
        case .stopping: "stopping"
        // Every failure reports the same label on purpose. The reason is a
        // `RecordingProblem` that can name storage errors, and those must not become
        // high-cardinality metadata.
        case .failed: "failed"
        }
    }
}

/// What GPeX reports about itself. One stable string, chosen once.
///
/// Not derived from the bundle identifier: `com.example.GPeX` is a placeholder that
/// will change before shipping, and a domain that changes with it would split the
/// historical data in two.
enum RecordingPerformanceDomain {
    static let identifier = "com.gbyo.gpex.recording"
}

/// The iOS 26 implementation: nothing at all.
///
/// StateReporting does not exist before iOS 27, and there is no older API worth
/// emulating, so the honest fallback is to do nothing rather than to log a shadow
/// copy of state the system will not use.
struct NoOpRecordingPerformanceReporter: RecordingPerformanceReporting {
    func transition(to phase: RecordingPhase) {}
}

enum RecordingPerformanceReporterFactory {
    /// The reporter for this OS version. StateReporting on iOS 27, nothing before it.
    static func make() -> any RecordingPerformanceReporting {
        #if canImport(StateReporting)
        if #available(iOS 27, *) {
            return StateReportingRecordingReporter(domain: RecordingPerformanceDomain.identifier)
        }
        #endif
        return NoOpRecordingPerformanceReporter()
    }
}
