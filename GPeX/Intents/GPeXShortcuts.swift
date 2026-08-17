import AppIntents

/// The spoken and searchable phrases for GPeX's intents.
///
/// Every phrase has to contain `\(.applicationName)`, so the app name is the anchor
/// rather than a generic verb — "start recording" on its own belongs to no app in
/// particular. No parameters: both intents take none, which is deliberate. There is
/// nothing to ask about at the moment a photographer wants to start.
struct GPeXShortcuts: AppShortcutsProvider {
    nonisolated static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start a \(.applicationName) recording",
                "Start \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: OpenCameraClockIntent(),
            phrases: [
                "Open Camera Clock in \(.applicationName)",
                "Show the \(.applicationName) camera clock",
            ],
            shortTitle: "Camera Clock",
            systemImageName: "clock"
        )
    }
}
