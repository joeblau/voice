import SwiftUI

/// Blau's type scale (#82).
///
/// Every style is a system text style, so all of them follow Dynamic Type
/// (up to the accessibility sizes) and Bold Text with no extra work. The
/// brand voice comes from SF Pro Rounded on the wordmark and titles; text the
/// user reads at length (the transcript, bullets) stays in the default design
/// for legibility. docs/branding.md has the table.
///
/// Apply with `.font(.brand(.transcript))` or `.brandTextStyle(.transcript)`.
/// The cases are declared from the largest style to the smallest.
enum BrandTextStyle: CaseIterable, Sendable {
    /// The "Blau" wordmark on the empty main screen.
    case wordmark
    /// The title of the current topic above the timeline's bullets (#56).
    case topicTitle
    /// A sheet's or section's heading.
    case heading
    /// What the user and Grok said, in the chat transcript (#42).
    case transcript
    /// A topic's bullets on the timeline (#56).
    case topicBullet
    /// Secondary text: hints, status lines, a compressed older topic's row.
    case caption
    /// Times and durations. Monospaced digits keep a running clock from
    /// jittering.
    case timestamp

    /// The Dynamic Type text style the style scales with.
    var textStyle: Font.TextStyle {
        switch self {
        case .wordmark: .largeTitle
        case .topicTitle: .title2
        case .heading: .headline
        case .topicBullet: .callout
        case .transcript: .body
        case .caption: .footnote
        case .timestamp: .caption
        }
    }

    var design: Font.Design {
        switch self {
        case .wordmark, .topicTitle, .heading: .rounded
        case .topicBullet, .transcript, .caption, .timestamp: .default
        }
    }

    var weight: Font.Weight {
        switch self {
        case .wordmark: .bold
        case .topicTitle, .heading: .semibold
        case .topicBullet, .transcript, .caption, .timestamp: .regular
        }
    }

    var usesMonospacedDigits: Bool {
        self == .timestamp
    }

    var font: Font {
        let font = Font.system(textStyle, design: design, weight: weight)
        return usesMonospacedDigits ? font.monospacedDigit() : font
    }
}

extension Font {
    /// A style from Blau's type scale.
    static func brand(_ style: BrandTextStyle) -> Font {
        style.font
    }
}

extension View {
    /// Sets the font to a style from Blau's type scale.
    func brandTextStyle(_ style: BrandTextStyle) -> some View {
        font(style.font)
    }
}

#Preview("Type scale") {
    List(BrandTextStyle.allCases, id: \.self) { style in
        Text(String(describing: style))
            .brandTextStyle(style)
    }
}

#Preview("Type scale, largest text") {
    List(BrandTextStyle.allCases, id: \.self) { style in
        Text(String(describing: style))
            .brandTextStyle(style)
    }
    .dynamicTypeSize(.accessibility5)
}
