import SwiftUI

/// The brand mark above the "Blau" wordmark (#82). The main screen shows it
/// until there is a conversation; the launch screen shows the same mark
/// alone, so launch hands over to it.
///
/// The mark scales with Dynamic Type alongside the wordmark. VoiceOver reads
/// the lockup as one heading, "Blau"; the mark itself is decorative.
struct BrandLockup: View {
    /// The mark's width at the default text size: its size on the launch screen.
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 96

    var body: some View {
        VStack(spacing: 16) {
            Image(BrandMark.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)
            Text(verbatim: "Blau")
                .brandTextStyle(.wordmark)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Lockup") {
    BrandLockup()
}

#Preview("Lockup, dark") {
    BrandLockup()
        .preferredColorScheme(.dark)
}
