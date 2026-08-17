import OSLog

/// Diagnostic logging for GPeX.
///
/// Precise coordinates are never written to the log in release builds. The only
/// coordinate-aware helper is `logCoordinateForDebugging`, which is compiled out
/// of release builds entirely and marks its values `.private` even in debug.
nonisolated enum Log {
    private static let subsystem = "com.example.GPeX"

    /// Recording lifecycle: start, stop, state transitions, Core Location diagnostics.
    static let recording = Logger(subsystem: subsystem, category: "recording")
    /// Process lifecycle: launch, background relaunch, recovery.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// SwiftData reads and writes.
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    /// GPX generation and sharing.
    static let export = Logger(subsystem: subsystem, category: "export")
}

extension Logger {
    /// Logs a coordinate for local debugging only.
    ///
    /// This is a no-op in release builds. Even in debug builds the values are
    /// marked `.private` so they are redacted when the log is collected from a
    /// device by anyone other than the developer attached to it.
    func logCoordinateForDebugging(_ label: String, latitude: Double, longitude: Double) {
        #if DEBUG
        debug("\(label, privacy: .public) lat=\(latitude, privacy: .private) lon=\(longitude, privacy: .private)")
        #endif
    }
}
