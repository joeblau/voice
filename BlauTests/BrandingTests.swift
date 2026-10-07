import BlauCore
import SwiftUI
import Testing
import UIKit

@testable import Blau

/// Guards the branding (#82): the design tokens in the asset catalog, the
/// launch screen and the app icon the build compiles from `AppIcon.icon`.
/// The unit-test bundle is hosted in the app, so `Bundle.main` is the built
/// Blau.app and these read its compiled `Assets.car` and `Info.plist`.
@MainActor
@Suite("Branding")
struct BrandingTests {
    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let dark = UITraitCollection(userInterfaceStyle: .dark)
    private static let appearances = [light, dark]

    private static func highContrast(_ traits: UITraitCollection) -> UITraitCollection {
        traits.modifyingTraits { $0.accessibilityContrast = .high }
    }

    private static func named(_ name: String) throws -> UIColor {
        try #require(UIColor(named: name, in: .main, compatibleWith: nil), "No color set named \(name)")
    }

    // MARK: Color tokens

    @Test(arguments: BrandColor.allCases.map(\.assetName) + TopicDotColor.assetNames)
    func tokenIsInTheAssetCatalogWithADarkVariant(name: String) throws {
        let color = try Self.named(name)
        let light = color.resolvedColor(with: Self.light)
        let dark = color.resolvedColor(with: Self.dark)
        #expect(Contrast.components(light) != Contrast.components(dark), "\(name) has no dark variant")
    }

    @Test(arguments: [BrandColor.accent, .recording])
    func tokenHasIncreasedContrastVariants(token: BrandColor) throws {
        let color = try Self.named(token.assetName)
        for traits in Self.appearances {
            let standard = color.resolvedColor(with: traits)
            let increased = color.resolvedColor(with: Self.highContrast(traits))
            #expect(Contrast.components(standard) != Contrast.components(increased))
            // Increased contrast must actually contrast more with the background.
            let background = UIColor.systemBackground.resolvedColor(with: traits)
            #expect(Contrast.ratio(increased, background) > Contrast.ratio(standard, background))
        }
    }

    /// actool records `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` as
    /// `NSAccentColorName`, which makes the color set the app-wide tint.
    @Test func accentIsTheGlobalAccentColor() {
        #expect(Bundle.main.infoDictionary?["NSAccentColorName"] as? String == BrandColor.accent.assetName)
    }

    /// The accent and the recording tint are used for text and glyphs, so they
    /// meet WCAG AA for text (4.5:1) on the system background in both
    /// appearances.
    @Test(arguments: [BrandColor.accent, .recording])
    func tintsMeetTextContrastOnTheBackground(token: BrandColor) throws {
        let color = try Self.named(token.assetName)
        for traits in Self.appearances {
            let ratio = Contrast.ratio(
                color.resolvedColor(with: traits),
                UIColor.systemBackground.resolvedColor(with: traits)
            )
            #expect(ratio >= 4.5, "\(token.assetName) is \(ratio):1 in \(traits.userInterfaceStyle.rawValue)")
        }
    }

    /// The light accent fills the record button behind a white glyph.
    @Test func whiteGlyphOnTheLightAccentMeetsTextContrast() throws {
        let accent = try Self.named(BrandColor.accent.assetName).resolvedColor(with: Self.light)
        #expect(Contrast.ratio(accent, .white) >= 4.5)
    }

    /// Timeline dots are graphics, not text: WCAG's non-text minimum (3:1)
    /// on the plain and the grouped background, in both appearances.
    @Test(arguments: TopicDotColor.assetNames)
    func topicDotMeetsNonTextContrast(name: String) throws {
        let color = try Self.named(name)
        for traits in Self.appearances {
            for background in [UIColor.systemBackground, .secondarySystemBackground] {
                let ratio = Contrast.ratio(color.resolvedColor(with: traits), background.resolvedColor(with: traits))
                #expect(ratio >= 3, "\(name) is \(ratio):1 in \(traits.userInterfaceStyle.rawValue)")
            }
        }
    }

    @Test func topicDotsAreDistinct() throws {
        for traits in Self.appearances {
            let colors = try TopicDotColor.assetNames.map { try Self.named($0).resolvedColor(with: traits) }
            #expect(Set(colors.map { Contrast.components($0).description }).count == TopicPalette.count)
        }
    }

    @Test func topicDotNamesFollowThePaletteSlots() {
        #expect(TopicDotColor.assetNames.count == TopicPalette.count)
        #expect(TopicDotColor.assetNames.first == "TopicDot0")
        #expect(TopicDotColor.assetName(forSlot: TopicPalette.slot(forColorSeed: 0xAB12)) == "TopicDot2")
    }

    // MARK: Launch screen

    private var launchScreen: [String: Any] {
        get throws {
            try #require(Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any])
        }
    }

    @Test func launchScreenBackgroundMatchesTheMainScreen() throws {
        let name = try #require(try launchScreen["UIColorName"] as? String)
        #expect(name == BrandColor.launchBackground.assetName)
        let color = try Self.named(name)
        for traits in Self.appearances {
            #expect(
                Contrast.components(color.resolvedColor(with: traits))
                    == Contrast.components(UIColor.systemBackground.resolvedColor(with: traits))
            )
        }
    }

    @Test func launchScreenShowsTheBrandMarkInBothAppearances() throws {
        let name = try #require(try launchScreen["UIImageName"] as? String)
        #expect(name == BrandMark.assetName)
        for traits in Self.appearances {
            let image = try #require(UIImage(named: name, in: .main, compatibleWith: traits))
            #expect(image.size == CGSize(width: 96, height: 96))
        }
    }

    // MARK: App icon

    @Test func appIconIsCompiledFromTheIconComposerDocument() throws {
        let icons = try #require(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
        // actool's flattened fallback for the home screen, next to Assets.car.
        let files = try #require(primary["CFBundleIconFiles"] as? [String])
        #expect(!files.isEmpty)
        for file in files {
            #expect(Bundle.main.path(forResource: "\(file)@2x", ofType: "png") != nil, "Missing \(file)@2x.png")
        }
    }

    // MARK: Typography

    @Test func everyTextStyleFollowsDynamicType() {
        for style in BrandTextStyle.allCases {
            let uiStyle = UIKitTextStyle.of(style.textStyle)
            let standard = UIFont.preferredFont(
                forTextStyle: uiStyle,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            )
            let largest = UIFont.preferredFont(
                forTextStyle: uiStyle,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
            )
            #expect(largest.pointSize > standard.pointSize, "\(style) does not scale")
        }
    }

    /// The scale is declared from the largest style to the smallest.
    @Test func scaleIsOrderedFromLargestToSmallest() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let sizes = BrandTextStyle.allCases.map {
            UIFont.preferredFont(forTextStyle: UIKitTextStyle.of($0.textStyle), compatibleWith: traits).pointSize
        }
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func onlyTimestampsUseMonospacedDigits() {
        #expect(BrandTextStyle.allCases.filter(\.usesMonospacedDigits) == [.timestamp])
    }
}

/// WCAG 2 relative luminance and contrast ratio.
private enum Contrast {
    static func components(_ color: UIColor) -> [Double] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // Rounded so that colors stored as 8-bit hex compare equal.
        return [red, green, blue, alpha].map { (Double($0) * 255).rounded() / 255 }
    }

    static func luminance(_ color: UIColor) -> Double {
        let linear = components(color).prefix(3).map { channel in
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ first: UIColor, _ second: UIColor) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private enum UIKitTextStyle {
    static func of(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
