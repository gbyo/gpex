import AppIntents

/// Open the Camera Clock screen.
///
/// The screen exists to be photographed, so the intent's only job is to put it in
/// front of the user. All of the clock's behaviour — the 10 Hz redraws, the idle
/// timer, the UTC offset — stays in `CameraClockView`.
struct OpenCameraClockIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Open Camera Clock"
    nonisolated static let description = IntentDescription(
        "Shows the Camera Clock so you can photograph it and measure your camera's drift.",
        categoryName: "Camera Clock"
    )

    /// There is nothing to show unless GPeX is on screen.
    nonisolated static let openAppWhenRun = true

    /// Resolved by `AppDependencyManager` during the system's perform flow.
    /// Not `private`, so a test can substitute an implementation directly —
    /// outside that flow there is no manager to resolve it.
    @Dependency var actions: any GPeXIntentActions

    @MainActor
    func perform() async throws -> some IntentResult {
        actions.openCameraClock()
        return .result()
    }
}
