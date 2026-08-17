import ActivityKit
import Foundation

/// The vocabulary shared between GPeX and its Live Activity extension.
///
/// This is the *only* file compiled into both targets. It deliberately contains no
/// recording engine, no Core Location, no SwiftData and no coordinates — just the
/// values the Lock Screen is allowed to know and the words it uses to say them.
///
/// Everything here is `nonisolated`: the project compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and ActivityKit hands these values to
/// its own executor when updating an activity, so a main-actor-isolated conformance to
/// `ActivityAttributes` would not compile.

// MARK: - Status

/// What the Live Activity says a recording is doing.
///
/// A presentation enum, not a state machine. `RecordingCoordinator` owns the real states;
/// this is a lossy projection of them chosen for a two-second glance at a locked phone.
/// Core Location's vocabulary never reaches it.
nonisolated enum RecordingLiveStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case waitingForAuthorization
    case acquiringLocation
    case moving
    case stationary
    case temporarilyUnavailable
    case stopping
}

extension RecordingLiveStatus {
    var title: String {
        switch self {
        case .waitingForAuthorization: "Waiting for Location Access"
        case .acquiringLocation: "Acquiring Location"
        case .moving: "Moving"
        case .stationary: "Stationary"
        case .temporarilyUnavailable: "Location Temporarily Unavailable"
        case .stopping: "Finishing Recording"
        }
    }

    /// A quiet second line, where one earns its place.
    ///
    /// Never the word "Paused". A stationary recording is still running, and it resumes by
    /// itself the moment the photographer walks — saying otherwise would invite them to
    /// stop and restart, which is exactly the wrong reaction.
    var detail: String? {
        switch self {
        case .stationary: "Saving battery"
        case .waitingForAuthorization, .acquiringLocation, .moving,
             .temporarilyUnavailable, .stopping: nil
        }
    }

    /// Status is carried by words and a symbol, never by colour alone.
    var symbolName: String {
        switch self {
        case .waitingForAuthorization: "lock.shield"
        case .acquiringLocation: "location.magnifyingglass"
        case .moving: "figure.walk"
        case .stationary: "figure.stand"
        case .temporarilyUnavailable: "location.slash"
        case .stopping: "stop.circle"
        }
    }

    /// Whether a current horizontal accuracy describes anything.
    ///
    /// While acquiring there is no fix yet, and while location is unavailable the last
    /// accuracy describes a position the device may have left. Showing a stale radius in
    /// either case would overstate what GPeX knows.
    var showsAccuracy: Bool {
        switch self {
        case .moving, .stationary: true
        case .waitingForAuthorization, .acquiringLocation, .temporarilyUnavailable, .stopping: false
        }
    }
}

// MARK: - Activity attributes

/// The ActivityKit payload for one recording.
///
/// `sessionID` is the stable association between a GPeX recording and its Live
/// Activity: it is how a relaunched process finds the right activity instead of
/// adopting whichever one happens to be first.
///
/// `startedAt` is static because it never changes, and because it is what lets the
/// system render the elapsed timer by itself. No elapsed duration is ever sent through
/// ActivityKit.
nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    /// The dynamic half: only values that actually change, and nothing that reveals
    /// where the photographer is standing.
    ///
    /// No latitude, no longitude, no altitude, no speed, no course. A Live Activity is
    /// visible on a locked phone to anyone holding it, and none of that is needed to
    /// answer the one question it exists to answer.
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var status: RecordingLiveStatus
        /// Metres, as reported by Core Location. `nil` when no current fix describes a
        /// radius worth showing.
        var horizontalAccuracy: Double?
        /// The count the app has persisted. The Live Activity never counts anything.
        var pointCount: Int
        /// Precise Location is off. Recording continues; the Lock Screen says so quietly.
        var reducedAccuracy: Bool

        init(
            status: RecordingLiveStatus,
            horizontalAccuracy: Double? = nil,
            pointCount: Int = 0,
            reducedAccuracy: Bool = false
        ) {
            self.status = status
            self.horizontalAccuracy = horizontalAccuracy
            self.pointCount = pointCount
            self.reducedAccuracy = reducedAccuracy
        }
    }

    var sessionID: UUID
    var startedAt: Date
}

extension RecordingActivityAttributes.ContentState {
    /// `±7 m`, or `nil` when there is nothing honest to show.
    var accuracyText: String? {
        guard status.showsAccuracy, let horizontalAccuracy else { return nil }
        return RecordingText.accuracy(horizontalAccuracy)
    }

    var spokenAccuracy: String? {
        guard status.showsAccuracy, let horizontalAccuracy else { return nil }
        return RecordingText.spokenAccuracy(horizontalAccuracy)
    }

    /// `38 locations`
    var locationsText: String { RecordingText.locations(pointCount) }

    /// `38 locations recorded` — also the VoiceOver label for the count.
    var locationsRecordedText: String { RecordingText.locationsRecorded(pointCount) }
}

// MARK: - Words

/// The words GPeX uses on system surfaces.
///
/// Lives in the shared file so the Lock Screen and the in-app recording screen cannot
/// drift apart: `Formatters.accuracy` forwards here rather than keeping a second copy.
nonisolated enum RecordingText {
    /// What the Lock Screen calls this app.
    ///
    /// Matches `CFBundleDisplayName`, so the Live Activity is named the same as the icon
    /// sitting next to it on the Home Screen.
    static let lockScreenTitle = "GPeX Recording"

    /// The Dynamic Island's expanded heading, where horizontal space is scarce.
    static let compactTitle = "Recording"

    static let reducedAccuracyTitle = "Reduced Accuracy"
    static let reducedAccuracySymbol = "exclamationmark.triangle"

    /// `±7 m`, localised to the reader's units.
    static func accuracy(_ meters: Double) -> String {
        "±\(measurement(meters, width: .abbreviated))"
    }

    /// `Accuracy within 7 meters` — spelled out, because VoiceOver reads `±` poorly.
    static func spokenAccuracy(_ meters: Double) -> String {
        "Accuracy within \(measurement(meters, width: .wide))"
    }

    /// `1 location` / `38 locations`
    static func locations(_ count: Int) -> String {
        count == 1 ? "1 location" : "\(count) locations"
    }

    /// `1 location recorded` / `38 locations recorded`
    static func locationsRecorded(_ count: Int) -> String {
        count == 1 ? "1 location recorded" : "\(count) locations recorded"
    }

    private static func measurement(
        _ meters: Double,
        width: Measurement<UnitLength>.FormatStyle.UnitWidth
    ) -> String {
        Measurement<UnitLength>(value: meters.rounded(), unit: .meters)
            .formatted(
                .measurement(
                    width: width,
                    usage: .general,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }
}

// MARK: - Deep link

/// The one interaction the Live Activity offers: open the recording it describes.
///
/// Not a routing framework. Tapping cannot change recording state — stopping a
/// multi-hour track by brushing a Lock Screen button would be expensive, and an App
/// Intent that mutated the recording would open a second route into the state machine.
nonisolated enum RecordingDeepLink {
    static let scheme = "gpex"
    static let activeRecordingHost = "recording"

    /// `gpex://recording`
    static var activeRecording: URL? {
        URL(string: "\(scheme)://\(activeRecordingHost)")
    }

    static func isActiveRecording(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == activeRecordingHost
    }
}
