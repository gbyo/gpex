import Foundation

/// Turns Core Location's diagnostics into plain sentences.
///
/// Framework vocabulary stays in the log. Nothing here mentions authorization
/// constants, service sessions or accuracy authorization.
extension RecordingPhase {
    var headline: String {
        switch self {
        case .idle: "Ready to record"
        case .waitingForAuthorization: "Waiting for permission…"
        case .acquiringLocation: "Acquiring location…"
        case .moving: "Recording"
        case .stationary: "Recording"
        case .temporarilyUnavailable: "Recording"
        case .stopping: "Stopping…"
        case .failed(let problem): problem.title
        }
    }

    /// The activity line: `Moving`, `Stationary`, or why nothing is arriving.
    var activityTitle: String? {
        switch self {
        case .moving: "Moving"
        case .stationary: "Stationary"
        case .temporarilyUnavailable: "Location unavailable"
        case .idle, .waitingForAuthorization, .acquiringLocation, .stopping, .failed: nil
        }
    }

    var activityDetail: String? {
        switch self {
        case .stationary:
            // Deliberately not "Paused": the recording is still running, and it will
            // pick up again by itself as soon as the photographer moves.
            "Saving battery"
        case .temporarilyUnavailable:
            "Recording continues. Positions resume when a fix is available."
        case .waitingForAuthorization:
            "Allow location access to record this session."
        case .acquiringLocation:
            "The session start time is already saved."
        case .idle, .moving, .stopping, .failed:
            nil
        }
    }
}

extension RecordingProblem {
    var title: String {
        switch self {
        case .locationServicesDisabled: "Location is off"
        case .permissionDenied: "Location access is off"
        case .permissionRestricted: "Location is unavailable"
        case .insufficientlyInUse: "Recording was interrupted"
        case .recoveredSessionMissing: "That recording is no longer available"
        case .storageFailure: "Could not save the recording"
        }
    }

    var detail: String {
        switch self {
        case .locationServicesDisabled:
            "Turn on Location Services to record this session."
        case .permissionDenied:
            "PhotoTrack needs location access while recording so photos can be matched to positions."
        case .permissionRestricted:
            "Location access is restricted on this iPhone."
        case .insufficientlyInUse:
            "iOS stopped location updates for PhotoTrack. Open PhotoTrack and start a new recording."
        case .recoveredSessionMissing:
            "The interrupted recording could not be found, so nothing was changed."
        case .storageFailure(let description):
            "PhotoTrack could not write to its database. \(description)"
        }
    }

    /// Whether pointing the user at Settings would actually help.
    var suggestsSettings: Bool {
        switch self {
        case .locationServicesDisabled, .permissionDenied: true
        case .permissionRestricted, .insufficientlyInUse, .recoveredSessionMissing, .storageFailure: false
        }
    }
}
