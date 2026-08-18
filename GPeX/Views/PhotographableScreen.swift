import SwiftUI

/// Prepares the display to be photographed: awake, bright, and free of overlays.
///
/// The same thing Wallet does for a barcode, and for the same reason — this screen
/// exists to be captured by another device, so the home indicator, Auto-Lock and a
/// dimmed backlight are all working against it.
///
/// Both effects are restored when the view goes away *and* when the app leaves the
/// foreground, because `onDisappear` alone would leave a phone that was locked mid-view
/// pinned at full brightness.
private struct PhotographableScreenModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    /// The user's own brightness, held only while it is overridden. Doubles as the
    /// "currently engaged" flag, so engaging twice cannot lose the original value.
    @State private var restoreBrightness: CGFloat?

    func body(content: Content) -> some View {
        content
            .persistentSystemOverlays(.hidden)
            .onAppear { engage() }
            .onDisappear { release() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    engage()
                } else {
                    release()
                }
            }
    }

    /// The window scene's screen rather than `UIScreen.main`, which no longer has a
    /// meaningful answer on a device that can drive more than one display.
    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    private func engage() {
        guard restoreBrightness == nil, let screen else { return }
        restoreBrightness = screen.brightness
        screen.brightness = 1.0
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func release() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let restoreBrightness, let screen {
            screen.brightness = restoreBrightness
        }
        restoreBrightness = nil
    }
}

extension View {
    /// Keeps this view awake, bright, and free of system overlays while it is visible.
    func photographableScreen() -> some View {
        modifier(PhotographableScreenModifier())
    }
}
