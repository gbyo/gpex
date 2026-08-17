import Foundation

nonisolated enum Formatters {
    /// `01:47:23` — the running recording timer.
    static func elapsedClock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(
            format: "%02d:%02d:%02d",
            locale: nil,
            total / 3600, (total % 3600) / 60, total % 60
        )
    }

    /// Spoken form of an elapsed duration, for VoiceOver.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
    }

    /// `1 hr 42 min` — a finished session's length.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated))
        }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    /// `±7 m`, localised to the reader's units.
    static func accuracy(_ meters: Double) -> String {
        let measurement = Measurement<UnitLength>(value: meters.rounded(), unit: .meters)
        let formatted = measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .general,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
        )
        return "±\(formatted)"
    }

    /// `Aug 17, 2026`
    static func sessionDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// `5:42 PM`
    static func sessionTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// `Aug 17 · 1 hr 42 min`
    static func recentSessionSubtitle(startedAt: Date, endedAt: Date?) -> String {
        let day = startedAt.formatted(.dateTime.month(.abbreviated).day())
        guard let endedAt else { return "\(day) · Unfinished" }
        return "\(day) · \(compactDuration(endedAt.timeIntervalSince(startedAt)))"
    }

    /// `UTC−04:00`
    static func utcOffset(secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "−" : "+"
        let magnitude = abs(secondsFromGMT)
        return String(
            format: "UTC%@%02d:%02d",
            locale: nil,
            sign, magnitude / 3600, (magnitude % 3600) / 60
        )
    }
}
