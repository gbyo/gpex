import Foundation

/// How often a recording is willing to write a location down.
///
/// This is a **minimum persistence interval**, not a GPS polling interval. Nothing here
/// asks Core Location for anything, schedules anything or wakes anything up: GPeX
/// consumes whatever `CLLocationUpdate.liveUpdates(.default)` delivers, and this value
/// only decides which of those deliveries are worth a row in the database. Choosing one
/// minute therefore costs no more battery than choosing ten seconds — it simply keeps
/// fewer of the fixes Core Location was going to send anyway.
///
/// The raw value is the interval in seconds, which is what makes it durable: the recovery
/// marker and the user's preference both store the number, so an interval added or
/// removed later cannot silently change what an existing recording meant.
nonisolated enum LocationSaveInterval: Int, Sendable, Equatable, Hashable, CaseIterable, Codable,
                                       Identifiable {
    case tenSeconds = 10
    case twentySeconds = 20
    case thirtySeconds = 30
    case oneMinute = 60

    /// What a recording uses when nobody has chosen anything.
    ///
    /// Thirty seconds is the recommendation because a photographer working one field
    /// mostly stands still: it is dense enough that a walk to the far end of a pitch is
    /// several points, and sparse enough that an afternoon of standing still is not
    /// thousands of rows describing the same square metre.
    static let `default`: LocationSaveInterval = .thirtySeconds

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    /// The one interval marked as recommended in the picker.
    var isRecommended: Bool { self == .default }

    /// `30 seconds` — the full phrase, for a picker row or a sentence.
    var label: String {
        Duration.seconds(rawValue)
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide, maximumUnitCount: 1))
    }

    /// `30 seconds (Recommended)` — a row in the picker.
    var pickerLabel: String {
        isRecommended ? "\(label) (Recommended)" : label
    }

    /// `Saving a location every 30 seconds` — the running recording's own description of
    /// its cadence.
    var cadenceDescription: String {
        "Saving a location every \(label)"
    }

    /// Reads a stored number back, falling back to the default rather than guessing.
    ///
    /// `0` is what `UserDefaults` returns for a key that was never written, so an absent
    /// preference and an unrecognised one take the same, safe path.
    init(storedSeconds: Int) {
        self = LocationSaveInterval(rawValue: storedSeconds) ?? .default
    }
}
