import SwiftUI

extension View {
    /// Reads a thin progress bar (a few points tall) as one plain element
    /// at least `minHeight` tall, centered on the bar, without changing the
    /// layout: VoiceOver says "`label`, `value`", and the bar isn't an
    /// element of its own.
    ///
    /// Left to itself, a 4 pt `ProgressView` is an element 4 pt tall, which
    /// the accessibility audit (and Accessibility Inspector) reports as
    /// "Hit area is too small" (#81).
    func accessibilityProgressBar(
        _ label: LocalizedStringKey, value: Text, identifier: String, minHeight: CGFloat = 44
    ) -> some View {
        accessibilityHidden(true)
            .background {
                Color.clear
                    .frame(height: minHeight)
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityValue(value)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier(identifier)
            }
    }
}
