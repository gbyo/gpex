import SwiftUI

/// A clock to photograph before an event, so the camera's drift can be measured later.
///
/// Deliberately plain: high contrast, no animation, no chrome. `TimelineView` drives
/// the redraws so there is no timer to own or leak, and `photographableScreen()` keeps
/// the display awake, bright and overlay-free for exactly as long as this is visible.
struct CameraClockView: View {
    @State private var anchor = Date()
    @ScaledMetric(relativeTo: .largeTitle) private var timeFontSize: CGFloat = 56

    /// Locale-aware wall clock: 12- or 24-hour according to the reader's settings.
    private static let localTime = Date.FormatStyle.dateTime.hour().minute().second()

    private static let localDate = Date.FormatStyle(date: .long, time: .omitted)

    /// Fixed 24-hour UTC, independent of locale and calendar.
    ///
    /// Verbatim rather than a localised style on purpose: this reading is compared
    /// against a camera's own clock and against the `<time>` elements in the exported
    /// GPX, both of which are unambiguous 24-hour UTC. A reader in a 12-hour locale
    /// must still see 14:03:07 here.
    private static let utcTime = Date.VerbatimFormatStyle(
        format: """
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)
            """,
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    var body: some View {
        // Tenths are enough to measure camera drift, and 10 Hz is cheap.
        TimelineView(.periodic(from: anchor, by: 0.1)) { context in
            let date = context.date
            let tenths = Self.tenths(of: date)

            VStack(alignment: .leading, spacing: 18) {
                Text("CAMERA CLOCK")
                    .font(.caption.weight(.semibold))
                    .kerning(1.5)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(date.formatted(Self.localTime)).\(tenths)")
                        .font(.system(size: timeFontSize, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .accessibilityLabel("Local time \(date.formatted(Self.localTime))")

                    Text(date.formatted(Self.localDate))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("UTC \(date.formatted(Self.utcTime)).\(tenths)")
                        .font(.system(size: timeFontSize * 0.52, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .accessibilityLabel("Coordinated Universal Time \(date.formatted(Self.utcTime))")

                    Text(Formatters.utcOffset(secondsFromGMT: TimeZone.current.secondsFromGMT(for: date)))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Self.spokenOffset(for: date))
                }

                Spacer(minLength: 0)

                Text("Photograph this screen with your camera, then compare the two times to find the camera's drift.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            // No animation: a moving clock must not be interpolated, and the screen has
            // to be photographable at any instant.
            .transaction { $0.animation = nil }
        }
        .navigationTitle("Camera Clock")
        .navigationBarTitleDisplayMode(.inline)
        .photographableScreen()
    }

    private static func tenths(of date: Date) -> Int {
        let fraction = date.timeIntervalSince1970 - date.timeIntervalSince1970.rounded(.down)
        return min(9, Int(fraction * 10))
    }

    private static func spokenOffset(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        let direction = seconds < 0 ? "behind" : "ahead of"
        if minutes == 0 {
            return "\(hours) hours \(direction) Coordinated Universal Time"
        }
        return "\(hours) hours \(minutes) minutes \(direction) Coordinated Universal Time"
    }
}

#if DEBUG
#Preview("Camera clock") {
    NavigationStack {
        CameraClockView()
    }
}

#Preview("Camera clock · AX3") {
    NavigationStack {
        CameraClockView()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
