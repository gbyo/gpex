import Foundation

/// How this process was launched.
///
/// PhotoTrack talks to real Core Location hardware and writes to a real SwiftData
/// store in normal use. Both are replaced under test so the suites stay
/// deterministic and never depend on GPS hardware or on the simulator's location
/// permission alert.
nonisolated enum AppLaunchMode: Sendable {
    /// Normal user launch: real Core Location, on-disk store, recovery enabled.
    case normal
    /// XCUITest launch: scripted location events, in-memory store, seeded fixture data.
    case uiTesting
    /// Unit test launch. The app is only the test host; it should stay inert.
    case unitTesting

    /// Launch argument XCUITests pass to put the app into scripted-location mode.
    static let uiTestingArgument = "-GpExUITesting"

    static let current: AppLaunchMode = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .unitTesting
        }
        if ProcessInfo.processInfo.arguments.contains(uiTestingArgument) {
            return .uiTesting
        }
        return .normal
    }()

    /// Only a normal launch touches Core Location.
    var usesCoreLocation: Bool { self == .normal }

    /// Test launches never write to the user's real database.
    var usesOnDiskStore: Bool { self == .normal }

    /// A unit-test host must not resurrect a recording behind the test's back.
    var restoresInterruptedRecording: Bool { self == .normal || self == .uiTesting }

    /// UI tests get one completed fixture session so name/correction/export/delete
    /// tests do not each have to record one first.
    var seedsFixtureData: Bool { self == .uiTesting }
}
