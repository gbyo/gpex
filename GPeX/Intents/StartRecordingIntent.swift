import AppIntents

/// Start a recording from Siri, Spotlight or the Shortcuts app.
///
/// `openAppWhenRun` is not a convenience here, it is a requirement: the first start on
/// a new install creates the `CLServiceSession` that asks for When In Use and for
/// temporary full accuracy, and those are foreground decisions with UI attached. An
/// intent that started a recording in the background would either fail silently or
/// ask a question nobody is there to answer.
struct StartRecordingIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Start GPeX Recording"
    nonisolated static let description = IntentDescription(
        "Starts recording a GPS track so your camera photos can be matched to positions later.",
        categoryName: "Recording"
    )

    /// Location authorization and Precise Location are foreground questions.
    nonisolated static let openAppWhenRun = true

    /// Resolved by `AppDependencyManager` during the system's perform flow.
    /// Not `private`, so a test can substitute an implementation directly —
    /// outside that flow there is no manager to resolve it.
    @Dependency var actions: any GPeXIntentActions

    @MainActor
    func perform() async throws -> some IntentResult {
        // The whole implementation. Starting is idempotent because
        // `RecordingCoordinator.startRecording()` is: idle starts, and starting,
        // recording or stopping all decline to create a second session.
        await actions.startRecording()
        return .result()
    }
}
