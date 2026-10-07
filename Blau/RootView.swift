import SwiftUI

/// Top-level view hosted by the app's window. Placeholder until the main
/// screen scaffold lands; UI and launch tests anchor on its accessibility
/// identifier.
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

    var body: some View {
        Text("Blau")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

#Preview {
    RootView()
}
