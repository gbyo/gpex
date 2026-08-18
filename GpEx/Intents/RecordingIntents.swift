import AppIntents
import Foundation

/// Starts a recording from outside the app: the long-press menu on the Home Screen
/// icon, Spotlight, Siri or a Shortcut.
///
/// `openAppWhenRun` is deliberate. Starting a recording creates a `CLServiceSession`,
/// which is what asks for When In Use and temporary full accuracy — both of which need
/// the app in front of the user. Running headlessly would either stall on a prompt the
/// user cannot see, or start a recording that immediately fails.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription(
        "Begins a new PhotoTrack recording so your photos can be matched to where you took them.",
        categoryName: "Recording"
    )

    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = AppServices.shared.coordinator
        // A recording already in flight is the outcome the user wanted; say so rather
        // than reporting a failure.
        guard !coordinator.phase.isActive else {
            return .result()
        }
        await coordinator.startRecording()
        return .result()
    }
}

/// Ends the recording in progress. Paired with `StartRecordingIntent` so the same
/// long-press menu can finish what it started.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription(
        "Ends the PhotoTrack recording in progress and saves the track.",
        categoryName: "Recording"
    )

    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = AppServices.shared.coordinator
        guard coordinator.phase.isActive else {
            return .result()
        }
        await coordinator.stopRecording()
        return .result()
    }
}

/// What appears in the Home Screen icon's long-press menu, in Spotlight, and as Siri
/// phrases. Only two entries, so the menu stays a shortcut rather than a second UI.
struct PhotoTrackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Start a \(.applicationName) track"
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop my \(.applicationName) track"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
