import BlauCore
import SwiftUI

/// Blau's color tokens (#82). Each one is a color set in
/// `Blau/Resources/Assets.xcassets` with a light and a dark variant; the
/// accent and the recording tint also have increased-contrast variants.
/// docs/branding.md lists the values and the contrast each one meets.
///
/// Views use these instead of literal colors, so the brand is changed in the
/// asset catalog alone. `BrandingTests` checks that every token resolves.
enum BrandColor: String, CaseIterable, Sendable {
    /// Blau's blue (*blau*). It is also the app's global accent
    /// (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`), so `.tint` and
    /// `Color.accentColor` already use it.
    case accent = "AccentColor"
    /// The launch screen's background: the system background, so launch hands
    /// over to the main screen without a flash.
    case launchBackground = "LaunchBackground"
    /// Recording in progress: the record button while it stops a conversation.
    case recording = "RecordingTint"

    /// The color set's name in the asset catalog.
    var assetName: String { rawValue }

    var color: Color { Color(assetName) }
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
