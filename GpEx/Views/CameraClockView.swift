import SwiftUI

/// A clock to photograph before an event, so the camera's drift can be measured later.
///
/// Deliberately plain: high contrast, no animation, no chrome. `TimelineView` drives
/// the redraws so there is no timer to own or leak, and the idle timer is disabled only
/// while this screen is on screen.
struct CameraClockView: View {
    @State private var anchor = Date()
    @ScaledMetric(relativeTo: .largeTitle) private var timeFontSize: CGFloat = 56

    private static let localTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmmss")
        return formatter
    }()

    private static let localDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let utcTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

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
                    Text("\(Self.localTime.string(from: date)).\(tenths)")
                        .font(.system(size: timeFontSize, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .accessibilityLabel("Local time \(Self.localTime.string(from: date))")

                    Text(Self.localDate.string(from: date))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("UTC \(Self.utcTime.string(from: date)).\(tenths)")
                        .font(.system(size: timeFontSize * 0.52, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .accessibilityLabel("Coordinated Universal Time \(Self.utcTime.string(from: date))")

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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
