import SwiftUI

/// Settings → Developer → Performance HUD: shows or hides the debug
/// performance HUD (#71). Available in every build, TestFlight included.
struct PerformanceHUDToggle: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.performanceHUD
        Toggle(isOn: Binding(get: { controller.isVisible }, set: { controller.setVisible($0) })) {
            Label("Performance HUD", systemImage: "gauge.with.dots.needle.33percent")
        }
        .accessibilityIdentifier(PerformanceHUDAccessibility.settingsToggle)
    }

    /// The Developer section's footer.
    static var footer: some View {
        #if DEBUG
            Text(
                "The HUD shows frame rate, CPU, memory, thermal state and live pipeline latencies. "
                    + "Tap it to expand, drag to move. Triple-tap the main screen to show or hide it.")
        #else
            Text(
                "The HUD shows frame rate, CPU, memory, thermal state and live pipeline latencies. "
                    + "Tap it to expand, drag to move.")
        #endif
    }
}
