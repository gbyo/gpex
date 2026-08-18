import SwiftUI

/// The visual half of a recording status: a symbol and a tint.
///
/// Kept separate from `RecordingStatusText` because that file is deliberately
/// plain-language and testable without SwiftUI. Nothing here carries meaning on its
/// own — every symbol and colour in this file sits next to the wording from
/// `RecordingStatusText`, so a reader who cannot distinguish the colours, or who has
/// symbols suppressed, loses nothing.
extension RecordingPhase {
    /// The status symbol. Filled variants throughout, so the shapes stay legible at
    /// caption size and in the high-contrast accessibility settings.
    var symbolName: String {
        switch self {
        case .idle: "location"
        case .waitingForAuthorization: "lock.shield"
        case .acquiringLocation: "location.magnifyingglass"
        case .tracking: "location.fill"
        case .stationary: "pause.circle.fill"
        case .temporarilyUnavailable: "location.slash"
        case .stopping: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// The status tint.
    ///
    /// `.stationary` is deliberately not a warning colour: Core Location stopping
    /// delivery while the photographer stands still is the system working correctly,
    /// and colouring it amber would suggest the recording had a problem.
    var tint: Color {
        switch self {
        case .tracking: .green
        case .stationary: .secondary
        case .acquiringLocation, .waitingForAuthorization: .accentColor
        case .temporarilyUnavailable: .orange
        case .failed: .red
        case .idle, .stopping: .secondary
        }
    }

    /// Whether the symbol should animate. Only the two genuinely in-progress states
    /// move, so motion means "something is happening" rather than decoration.
    var symbolPulses: Bool {
        switch self {
        case .tracking, .acquiringLocation: true
        case .idle, .waitingForAuthorization, .stationary, .temporarilyUnavailable,
             .stopping, .failed: false
        }
    }
}

extension LocationQuality {
    /// A four-bar signal reading, the same idiom Wi-Fi and cellular use.
    var symbolName: String {
        switch self {
        case .excellent: "dot.radiowaves.up.forward"
        case .good: "dot.radiowaves.right"
        case .usable: "dot.radiowaves.left.and.right"
        case .poor: "antenna.radiowaves.left.and.right.slash"
        }
    }

    var tint: Color {
        switch self {
        case .excellent, .good: .green
        case .usable: .orange
        case .poor: .red
        }
    }
}
