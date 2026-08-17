import Foundation
import MetricKit
import OSLog

/// The whole of GPeX's deprecated MetricKit surface, in one type.
///
/// `MXMetricManager` and `MXMetricManagerSubscriber` are deprecated in favour of
/// `MetricManager`, and building against the iOS 27 SDK says so loudly. Confining
/// them here means the deprecation is one file's problem rather than the app's: when
/// the deployment target eventually reaches iOS 27, this file is deleted and nothing
/// else changes.
///
/// It is an `NSObject` because `MXMetricManagerSubscriber` requires one. Both
/// callbacks come in on an arbitrary queue, so everything it touches is either
/// immutable or `Sendable`.
@available(iOS, deprecated: 27.0, message: "Superseded by PerformanceMonitor's MetricManager path.")
nonisolated final class LegacyMetricKitReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let handler: any PerformanceReportHandling
    private var isSubscribed = false

    init(handler: any PerformanceReportHandling) {
        self.handler = handler
        super.init()
    }

    /// Subscribing twice would deliver every payload twice.
    func subscribe() {
        guard !isSubscribed else { return }
        isSubscribed = true
        MXMetricManager.shared.add(self)
        Log.metrics.info("Subscribed to legacy MetricKit payloads")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            handler.handleMetricReport(
                summary: "legacy metric payload \(Self.range(payload.timeStampBegin, payload.timeStampEnd))",
                json: payload.jsonRepresentation()
            )
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            handler.handleDiagnosticReport(
                summary: Self.summary(of: payload),
                json: payload.jsonRepresentation()
            )
        }
    }

    // MARK: - Summaries

    /// Counts only. Deliberately no call stacks, no binary names, nothing per-session.
    private static func summary(of payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        if let count = payload.crashDiagnostics?.count, count > 0 { parts.append("crash×\(count)") }
        if let count = payload.hangDiagnostics?.count, count > 0 { parts.append("hang×\(count)") }
        if let count = payload.cpuExceptionDiagnostics?.count, count > 0 { parts.append("cpu×\(count)") }
        if let count = payload.diskWriteExceptionDiagnostics?.count, count > 0 { parts.append("diskWrite×\(count)") }
        if let count = payload.appLaunchDiagnostics?.count, count > 0 { parts.append("launch×\(count)") }
        let detail = parts.isEmpty ? "none" : parts.joined(separator: " ")
        return "legacy diagnostic payload \(range(payload.timeStampBegin, payload.timeStampEnd)): \(detail)"
    }

    private static func range(_ begin: Date, _ end: Date) -> String {
        "over \(Int(end.timeIntervalSince(begin) / 3600))h"
    }
}
