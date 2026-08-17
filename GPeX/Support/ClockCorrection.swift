import Foundation

/// A camera clock correction, as the user thinks about it.
///
/// The stored value is `cameraClockOffsetSeconds`, defined as
/// `camera time - actual iPhone time`. A slow camera therefore has a *negative*
/// offset and a fast camera a positive one. This type is the only place that
/// conversion happens, so the sign cannot drift between the UI and the exporter.
nonisolated struct ClockCorrection: Sendable, Equatable {
    enum Direction: Sendable, Equatable, CaseIterable, Identifiable {
        /// The camera clock reads later than the iPhone: a positive offset.
        case fast
        /// The camera clock reads earlier than the iPhone: a negative offset.
        case slow

        var id: Self { self }
        var label: String {
            switch self {
            case .fast: "Fast"
            case .slow: "Slow"
            }
        }
    }

    var direction: Direction = .slow
    var hours: Int = 0
    var minutes: Int = 0
    var seconds: Int = 0

    static let none = ClockCorrection()

    init(direction: Direction = .slow, hours: Int = 0, minutes: Int = 0, seconds: Int = 0) {
        self.direction = direction
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    /// Decomposes a stored offset back into direction and units.
    init(offsetSeconds: Double) {
        let rounded = offsetSeconds.rounded()
        direction = rounded < 0 ? .slow : .fast
        let magnitude = Int(abs(rounded))
        hours = magnitude / 3600
        minutes = (magnitude % 3600) / 60
        seconds = magnitude % 60
    }

    var magnitudeSeconds: Int { hours * 3600 + minutes * 60 + seconds }

    /// The value stored on the session and added to every exported GPX timestamp.
    var offsetSeconds: Double {
        Double(direction == .slow ? -magnitudeSeconds : magnitudeSeconds)
    }

    var isNone: Bool { magnitudeSeconds == 0 }

    /// `None`, or `Camera was 5 seconds slow`.
    var summary: String {
        guard !isNone else { return "None" }
        let amount = Duration.seconds(magnitudeSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        return "Camera was \(amount) \(direction == .fast ? "fast" : "slow")"
    }

    /// `−00:00:05`, with an unambiguous sign.
    var signedAdjustment: String {
        let sign = isNone ? "" : (direction == .slow ? "−" : "+")
        return String(
            format: "%@%02d:%02d:%02d",
            locale: nil,
            sign, hours, minutes, seconds
        )
    }

    /// Spelled out for VoiceOver, where `−` is easy to miss.
    var spokenAdjustment: String {
        guard !isNone else { return "No adjustment" }
        let amount = Duration.seconds(magnitudeSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        return direction == .slow
            ? "Export timestamps shift earlier by \(amount)"
            : "Export timestamps shift later by \(amount)"
    }
}
