import BlauCore
import SwiftUI

/// Blau's color tokens (#82). Each one is a color set in
/// `Blau/Resources/Assets.xcassets` with a light and a dark variant; the
/// accent, the recording tint and the two fills also have increased-contrast
/// variants. docs/branding.md lists the values and the contrast each one
/// meets.
///
/// There are two kinds of token. A *tint* (`accent`, `recording`) is drawn on
/// the background as text or a glyph, so it gets lighter in dark mode and
/// with Increased Contrast. A *fill* (`accentFill`, `recordingFill`) is drawn
/// behind a white label, as a prominent button's background, so it stays deep
/// in dark mode and gets darker with Increased Contrast. One color can't do
/// both: the dark accent that reads well on black leaves a white label at
/// under 4.5:1.
///
/// Views use these instead of literal colors, so the brand is changed in the
/// asset catalog alone. `BrandingTests` checks that every token resolves.
enum BrandColor: String, CaseIterable, Sendable {
    /// Blau's blue (*blau*). It is also the app's global accent
    /// (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`), so `.tint` and
    /// `Color.accentColor` already use it.
    case accent = "AccentColor"
    /// The background of a prominent button in Blau's blue, behind its white
    /// label. Apply it with `brandProminentButtonStyle()`.
    case accentFill = "AccentFill"
    /// The launch screen's background: the system background, so launch hands
    /// over to the main screen without a flash.
    case launchBackground = "LaunchBackground"
    /// Recording in progress, as text or a glyph on the background.
    case recording = "RecordingTint"
    /// Recording in progress, behind a white label: the record button while
    /// it stops a conversation.
    case recordingFill = "RecordingFill"

    /// The color set's name in the asset catalog.
    var assetName: String { rawValue }

    var color: Color { Color(assetName) }

    /// The fills, drawn behind a white label.
    static let fills: [BrandColor] = [.accentFill, .recordingFill]
    /// The tints, drawn on the background as text or a glyph.
    static let tints: [BrandColor] = [.accent, .recording]
}

/// The topic timeline's dot colors (#82, used by the timeline in #56): one
/// color set per `TopicPalette` slot, named `TopicDot<slot>`.
enum TopicDotColor {
    /// The asset catalog name of a palette slot's color set.
    static func assetName(forSlot slot: Int) -> String {
        "TopicDot\(slot)"
    }

    /// Every slot's color set name, in slot order.
    static var assetNames: [String] {
        (0..<TopicPalette.count).map(assetName(forSlot:))
    }

    /// The dot color for a topic's `colorSeed`.
    static func color(forColorSeed seed: Int) -> Color {
        Color(assetName(forSlot: TopicPalette.slot(forColorSeed: seed)))
    }
}

extension Color {
    /// A brand color token.
    static func brand(_ token: BrandColor) -> Color {
        token.color
    }

    /// The timeline dot color for a topic, from its `colorSeed`, so a topic
    /// has the same color on every device.
    static func topicDot(colorSeed: Int) -> Color {
        TopicDotColor.color(forColorSeed: colorSeed)
    }
}

extension View {
    /// The prominent button style on a brand fill. The label is white, and
    /// every variant of the fill keeps it at 4.5:1 or more (docs/branding.md),
    /// which the global accent can't do in dark mode.
    func brandProminentButtonStyle(_ fill: BrandColor = .accentFill) -> some View {
        buttonStyle(.borderedProminent)
            .tint(fill.color)
    }
}

/// The brand mark: Blau's waveform, the icon's foreground, in the accent
/// blue. The same image is the launch screen's (`UILaunchScreen.UIImageName`).
enum BrandMark {
    static let assetName = "BrandMark"
}

#Preview("Brand colors") {
    List {
        Section("Brand") {
            ForEach(BrandColor.allCases, id: \.self) { token in
                LabeledContent(token.assetName) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(token.color)
                        .frame(width: 44, height: 28)
                }
            }
        }
        Section("Topic dots") {
            ForEach(0..<TopicPalette.count, id: \.self) { slot in
                LabeledContent(TopicDotColor.assetName(forSlot: slot)) {
                    Circle()
                        .fill(Color(TopicDotColor.assetName(forSlot: slot)))
                        .frame(width: 12, height: 12)
                }
            }
        }
    }
}
