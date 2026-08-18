import Foundation
import OSLog

/// The minimal "a recording is outstanding" marker.
///
/// This is the only thing GPeX keeps in `UserDefaults`. It exists because
/// `application(_:didFinishLaunchingWithOptions:)` has to decide *synchronously*
/// whether to rejoin Core Location, and opening a SwiftData store to find out is
/// too slow to preserve the outstanding-session continuity Core Location expects.
/// No location history is ever written here.
nonisolated struct RecoveryMarker: Sendable, Equatable {
    var sessionID: UUID
    var startedAt: Date
    /// The cadence the interrupted recording was running at, so resuming it does not
    /// silently change how often locations are saved half way through a session.
    var saveInterval: LocationSaveInterval

    init(sessionID: UUID, startedAt: Date, saveInterval: LocationSaveInterval = .default) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.saveInterval = saveInterval
    }
}

/// Reads and writes the recovery marker. Main-actor only, like the recording itself.
final class RecoveryMarkerStore {
    /// `true` from the moment the user taps Start until Stop has fully completed.
    static let recordingRequestedKey = "recordingRequested"
    static let sessionIDKey = "activeRecordingSessionID"
    static let startedAtKey = "activeRecordingStartedAt"
    static let saveIntervalKey = "activeRecordingSaveIntervalSeconds"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The outstanding recording, or `nil` if none was requested.
    ///
    /// Returns `nil` unless all three fields agree, so a half-written marker can
    /// never resurrect a recording that does not exist.
    func load() -> RecoveryMarker? {
        guard defaults.bool(forKey: Self.recordingRequestedKey) else { return nil }
        guard let idString = defaults.string(forKey: Self.sessionIDKey),
              let id = UUID(uuidString: idString),
              let startedAt = defaults.object(forKey: Self.startedAtKey) as? Date
        else {
            // Inconsistent marker: drop it rather than guess.
            Log.lifecycle.error("Discarding inconsistent recovery marker")
            clear()
            return nil
        }
        // Deliberately not part of the all-three-agree check above. A marker written by
        // a version of GPeX that predates the setting is perfectly valid; it simply
        // resumes at the default cadence rather than being thrown away.
        return RecoveryMarker(
            sessionID: id,
            startedAt: startedAt,
            saveInterval: LocationSaveInterval(storedSeconds: defaults.integer(forKey: Self.saveIntervalKey))
        )
    }

    func save(_ marker: RecoveryMarker) {
        defaults.set(marker.sessionID.uuidString, forKey: Self.sessionIDKey)
        defaults.set(marker.startedAt, forKey: Self.startedAtKey)
        defaults.set(marker.saveInterval.rawValue, forKey: Self.saveIntervalKey)
        // Written last so a partially written marker never reads as active.
        defaults.set(true, forKey: Self.recordingRequestedKey)
    }

    func clear() {
        // Cleared first for the same reason it is written last.
        defaults.set(false, forKey: Self.recordingRequestedKey)
        defaults.removeObject(forKey: Self.sessionIDKey)
        defaults.removeObject(forKey: Self.startedAtKey)
        defaults.removeObject(forKey: Self.saveIntervalKey)
    }
}
