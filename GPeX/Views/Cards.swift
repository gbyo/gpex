import SwiftUI

/// One labelled figure — a count, an accuracy — sized to sit beside its siblings.
///
/// The value is the loud part and the caption the quiet one, which is the opposite of
/// the `LabeledContent` rows these replaced: on the recording screen the numbers are
/// what a photographer glances at, not the words next to them.
struct StatCard<Value: View>: View {
    let caption: LocalizedStringKey
    let symbolName: String
    var tint: Color = .secondary
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(caption)
            } icon: {
                Image(systemName: symbolName)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)

            value
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// A short piece of bad news with an optional way to act on it.
///
/// Used for the states the photographer can do something about — Precise Location off,
/// background updates limited, a failed start — so they read as the same kind of thing
/// wherever they appear.
struct NoticeCard: View {
    let title: Text
    let detail: Text
    var symbolName: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var showsSettingsLink: Bool = false
    var onDismiss: (() -> Void)?

    /// For the fixed notices written here in source, which the String Catalog can see.
    init(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbolName: String = "exclamationmark.triangle.fill",
        tint: Color = .orange,
        showsSettingsLink: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.init(
            title: Text(title),
            detail: Text(detail),
            symbolName: symbolName,
            tint: tint,
            showsSettingsLink: showsSettingsLink,
            onDismiss: onDismiss
        )
    }

    /// For text chosen at runtime — `RecordingProblem`, whose wording is a `String`
    /// because the Live Activity's `Codable` state carries the same sentences.
    init(
        title: Text,
        detail: Text,
        symbolName: String = "exclamationmark.triangle.fill",
        tint: Color = .orange,
        showsSettingsLink: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.tint = tint
        self.showsSettingsLink = showsSettingsLink
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                title
                    .font(.headline)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(tint)
            }

            detail
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSettingsLink || onDismiss != nil {
                HStack(spacing: 12) {
                    if showsSettingsLink, let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: settings)
                    }
                    if let onDismiss {
                        Button("Dismiss", action: onDismiss)
                    }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview("Cards") {
    ScrollView {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                StatCard(caption: "Locations", symbolName: "mappin.and.ellipse") {
                    Text("128")
                }
                StatCard(caption: "Accuracy", symbolName: "dot.radiowaves.up.forward", tint: .green) {
                    Text("±8 m")
                }
            }

            NoticeCard(
                title: "Reduced Accuracy",
                detail: "Precise Location is off. Photo positioning may be inaccurate.",
                symbolName: "location.slash.fill",
                showsSettingsLink: true
            )

            NoticeCard(
                title: "Location access is off",
                detail: "GPeX needs location access while recording so photos can be matched to positions.",
                tint: .red,
                showsSettingsLink: true,
                onDismiss: {}
            )
        }
        .padding()
    }
}
#endif
