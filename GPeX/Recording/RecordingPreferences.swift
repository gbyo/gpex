import Foundation
import Observation
import OSLog

/// The recording choices that outlive one session.
///
/// There is exactly one of these, and it holds exactly one thing: how often the
/// photographer wants a location written down. It is separate from `RecoveryMarkerStore`
/// because the two answer different questions — a marker says "a recording is
/// outstanding", a preference says "this is how I like to record" — and because a
/// preference has to survive the marker being cleared at every stop.
///
/// `@Observable` so the picker on the home screen reads the same value the next recording
/// will actually start with, with no copy in the view to drift out of step.
@Observable
final class RecordingPreferences {
    /// Stored as a plain number of seconds, so a value written by one version of GPeX
    /// still reads correctly in the next one.
    static let saveIntervalKey = "savedLocationIntervalSeconds"

    @ObservationIgnored private let defaults: UserDefaults

    /// The interval the next recording will start with, remembered across launches.
    ///
    /// Written through `setSaveInterval(_:)` rather than by a `didSet`, because
    /// `@Observable` owns the accessors of a stored property and a property observer
    /// cannot be attached to one.
    private(set) var saveInterval: LocationSaveInterval

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A key that was never written reads as `0`, which resolves to the default
        // rather than being mistaken for an interval of no seconds at all.
        self.saveInterval = LocationSaveInterval(
            storedSeconds: defaults.integer(forKey: Self.saveIntervalKey)
        )
    }

    func setSaveInterval(_ interval: LocationSaveInterval) {
        guard interval != saveInterval else { return }
        saveInterval = interval
        defaults.set(interval.rawValue, forKey: Self.saveIntervalKey)
        Log.recording.info("Saved-location interval set to \(interval.rawValue, privacy: .public)s")
    }
}
