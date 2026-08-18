import Foundation
import Testing
@testable import GPeX

@Suite("Recording performance reporting")
@MainActor
struct RecordingPerformanceTests {

    // MARK: - The vocabulary

    @Test("Every phase maps to its fixed state label")
    func phaseLabels() {
        #expect(RecordingPhase.waitingForAuthorization.performanceStateLabel == "authorization")
        #expect(RecordingPhase.acquiringLocation.performanceStateLabel == "acquiring")
        #expect(RecordingPhase.tracking.performanceStateLabel == "tracking")
        #expect(RecordingPhase.stationary.performanceStateLabel == "stationary")
        #expect(RecordingPhase.temporarilyUnavailable.performanceStateLabel == "unavailable")
        #expect(RecordingPhase.stopping.performanceStateLabel == "stopping")
        #expect(RecordingPhase.failed(.permissionDenied).performanceStateLabel == "failed")
        // Idle is the absence of a state, not a state called "idle".
        #expect(RecordingPhase.idle.performanceStateLabel == nil)
    }

    @Test("A failure's reason never becomes part of the reported label")
    func failureLabelsCarryNoDetail() {
        // A storage failure's message is arbitrary text from the system. Reporting it
        // would be both high-cardinality and a potential leak.
        let problems: [RecordingProblem] = [
            .permissionDenied,
            .locationServicesDisabled,
            .storageFailure("disk full at /Users/someone/Soccer vs Greenwood"),
        ]
        let labels = problems.map { RecordingPhase.failed($0).performanceStateLabel }
        #expect(labels.allSatisfy { $0 == "failed" })
    }

    @Test("The reporting domain is stable and independent of the bundle identifier")
    func domainIsStable() {
        #expect(RecordingPerformanceDomain.identifier == "com.gbyo.gpex.recording")
        // `com.example.GPeX` is a placeholder that will change before shipping.
        #expect(!RecordingPerformanceDomain.identifier.contains("com.example"))
    }

    // MARK: - Transitions

    @Test("Real transitions are reported, from start through stop")
    func reportsRecordingLifecycle() async throws {
        let harness = try RecordingHarness()
        let spy = try #require(harness.performanceSpy)

        await harness.coordinator.startRecording()
        #expect(spy.reportedLabels == ["authorization"])

        // A diagnostic saying nothing is wrong moves it off "waiting for permission".
        harness.provider.emit(SessionDiagnostic(source: .serviceSession))
        try await waitUntil("acquiring") { harness.coordinator.phase == .acquiringLocation }

        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }

        harness.deliver(sample(2, stationary: true))
        try await waitUntil("stationary") { harness.coordinator.phase == .stationary }

        await harness.coordinator.stopRecording()

        #expect(spy.reportedLabels == ["authorization", "acquiring", "tracking", "stationary", "stopping", nil])
    }

    @Test("Re-asserting the same phase is not reported again")
    func duplicateTransitionsAreIgnored() async throws {
        let harness = try RecordingHarness()
        let spy = try #require(harness.performanceSpy)

        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }
        let afterFirstFix = spy.reportedPhases.count

        // Three more fixes at new positions. The phase never changes, so nothing is reported.
        harness.deliver(sample(2, positionB))
        harness.deliver(sample(3, positionC))
        harness.deliver(sample(4, positionA))
        try await waitUntil("four points") { harness.coordinator.recordedPointCount == 4 }

        #expect(spy.reportedPhases.count == afterFirstFix)
        #expect(spy.reportedLabels.last == "tracking")
    }

    @Test("A second Start reports nothing, because nothing transitioned")
    func repeatedStartReportsNothing() async throws {
        let harness = try RecordingHarness()
        let spy = try #require(harness.performanceSpy)

        await harness.coordinator.startRecording()
        let afterFirstStart = spy.reportedPhases.count
        await harness.coordinator.startRecording()

        #expect(spy.reportedPhases.count == afterFirstStart)
    }

    @Test("Idle clears the state rather than reporting one")
    func stoppingClearsTheState() async throws {
        let harness = try RecordingHarness()
        let spy = try #require(harness.performanceSpy)

        await harness.coordinator.startRecording()
        await harness.coordinator.stopRecording()

        #expect(spy.reportedPhases.last == .idle)
        #expect(spy.reportedLabels.last == .some(nil))
    }

    @Test("A failure is reported, and dismissing it clears the state")
    func failureAndRecoveryAreReported() async throws {
        let harness = try RecordingHarness()
        let spy = try #require(harness.performanceSpy)

        await harness.coordinator.startRecording()
        var diagnostic = SessionDiagnostic(source: .serviceSession)
        diagnostic.authorizationDenied = true
        harness.provider.emit(diagnostic)
        try await waitUntil("failed") { harness.coordinator.phase == .failed(.permissionDenied) }

        #expect(spy.reportedLabels.last == "failed")

        harness.coordinator.dismissFailure()
        #expect(spy.reportedLabels.last == .some(nil))
    }

    // MARK: - Isolation from recording

    @Test("A reporter that fails on every call cannot fail or stop a recording")
    func reportingFailuresCannotBreakRecording() async throws {
        let reporter = FailingPerformanceReporter()
        let harness = try RecordingHarness(performanceReporter: reporter)

        await harness.coordinator.startRecording()
        let sessionID = try #require(harness.coordinator.state.activeRecording?.sessionID)

        harness.deliver(sample(1))
        harness.deliver(sample(2, positionB, stationary: true))
        try await waitUntil("two points") { harness.coordinator.recordedPointCount == 2 }

        await harness.coordinator.stopRecording()

        // The recording ran and closed exactly as it does with a working reporter.
        #expect(harness.coordinator.phase == .idle)
        let snapshot = try await #require(harness.store.sessionSnapshot(id: sessionID))
        #expect(snapshot.endedAt != nil)
        #expect(try await harness.store.pointCount(sessionID: sessionID) == 2)
        // And it really was failing the whole time.
        #expect(reporter.swallowedFailures > 0)
    }

    @Test("A recording works with no performance reporting at all")
    func iOS26FallbackNeedsNoStateReporting() async throws {
        // `NoOpRecordingPerformanceReporter` is what iOS 26 gets: StateReporting is
        // never imported, constructed or called on that path.
        let harness = try RecordingHarness(performanceReporter: NoOpRecordingPerformanceReporter())

        await harness.coordinator.startRecording()
        harness.deliver(sample(1))
        try await waitUntil("tracking") { harness.coordinator.phase == .tracking }
        await harness.coordinator.stopRecording()

        #expect(harness.coordinator.phase == .idle)
    }

    @Test("The factory picks a reporter for whatever OS this is")
    func factoryAlwaysProducesAReporter() {
        // On iOS 26 this is the no-op; on iOS 27 it is the StateReporting one. Either
        // way the coordinator gets something, and neither can throw.
        let reporter = RecordingPerformanceReporterFactory.make()
        reporter.transition(to: .tracking)
        reporter.transition(to: .tracking)
        reporter.transition(to: .idle)

        if #available(iOS 27, *) {
            #expect(!(reporter is NoOpRecordingPerformanceReporter))
        } else {
            #expect(reporter is NoOpRecordingPerformanceReporter)
        }
    }
}

@Suite("Performance report archive")
nonisolated struct PerformanceReportArchiveTests {

    private func makeArchive() -> (PerformanceReportArchive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (PerformanceReportArchive(directory: directory), directory)
    }

    @Test("Retention is capped, keeping the most recent reports")
    func retentionIsCapped() throws {
        let (archive, directory) = makeArchive()
        defer { try? FileManager.default.removeItem(at: directory) }

        let total = PerformanceReportArchive.retainedReportCount + 4
        for sequence in 1...total {
            archive.store(Data("report \(sequence)".utf8), kind: .diagnostic, sequence: sequence)
        }

        let stored = archive.storedReports(kind: .diagnostic)
        #expect(stored.count == PerformanceReportArchive.retainedReportCount)

        // The survivors are the newest, in order.
        let contents = try stored.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(contents == ((total - PerformanceReportArchive.retainedReportCount + 1)...total).map { "report \($0)" })
    }

    @Test("Metric and diagnostic reports are capped separately")
    func kindsAreCappedIndependently() {
        let (archive, directory) = makeArchive()
        defer { try? FileManager.default.removeItem(at: directory) }

        for sequence in 1...(PerformanceReportArchive.retainedReportCount + 3) {
            archive.store(Data("m".utf8), kind: .metric, sequence: sequence)
        }
        archive.store(Data("d".utf8), kind: .diagnostic, sequence: 1)

        #expect(archive.storedReports(kind: .metric).count == PerformanceReportArchive.retainedReportCount)
        #expect(archive.storedReports(kind: .diagnostic).count == 1)
    }

    @Test("An unwritable archive is silently ignored")
    func unwritableArchiveDoesNotThrow() {
        // No directory at all: the archive is an inspection aid, so losing it is not
        // an error anything should react to.
        let archive = PerformanceReportArchive(directory: nil)
        archive.store(Data("report".utf8), kind: .metric, sequence: 1)
        #expect(archive.storedReports(kind: .metric).isEmpty)
    }
}
