import BlauTelemetry
import SwiftUI

/// The accessibility identifiers UI tests use for the HUD.
enum PerformanceHUDAccessibility {
    static let hud = "blau.hud"
    static let expanded = "blau.hud.expanded"
    static let settingsToggle = "settings.developer.performanceHUD"
}

/// The debug performance HUD (#71): a small translucent panel over the app
/// with live pipeline health. Tap it to switch between the compact rows and
/// every section; drag it anywhere. It remembers both.
struct PerformanceHUDView: View {
    @Bindable var controller: PerformanceHUDController

    @State private var dragOffset: CGSize = .zero
    @State private var panelSize: CGSize = CGSize(width: 180, height: 90)

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            panel
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    panelSize = $0
                }
                .position(center(in: bounds))
                .gesture(drag(in: bounds))
        }
        .ignoresSafeArea(.keyboard)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.isExpanded {
                ScrollView {
                    expanded
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                rows(controller.readout.compact)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .frame(width: controller.isExpanded ? 320 : 230, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: controller.readout.level == .normal ? 0.5 : 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            controller.isExpanded.toggle()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Performance HUD")
        .accessibilityHint(controller.isExpanded ? "Shows fewer values" : "Shows every value")
        .accessibilityAction(named: controller.isExpanded ? "Collapse" : "Expand") {
            controller.isExpanded.toggle()
        }
        .accessibilityIdentifier(PerformanceHUDAccessibility.hud)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(controller.readout.sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    rows(section.rows)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PerformanceHUDAccessibility.expanded)
    }

    private func rows(_ rows: [PerformanceHUDReadout.Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(row.value)
                        .foregroundStyle(color(row.level))
                        // One line when compact, so the panel keeps its size
                        // (and isn't laid out again) as the values change.
                        .lineLimit(controller.isExpanded ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: controller.isExpanded)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Position

    /// The panel's centre: the stored position plus the drag in progress,
    /// kept fully inside `bounds`.
    private func center(in bounds: CGSize) -> CGPoint {
        let stored = CGPoint(x: controller.position.x * bounds.width, y: controller.position.y * bounds.height)
        return clamp(CGPoint(x: stored.x + dragOffset.width, y: stored.y + dragOffset.height), in: bounds)
    }

    private func clamp(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let halfWidth = min(panelSize.width, bounds.width) / 2
        let halfHeight = min(panelSize.height, bounds.height) / 2
        return CGPoint(
            x: min(max(point.x, halfWidth), max(bounds.width - halfWidth, halfWidth)),
            y: min(max(point.y, halfHeight), max(bounds.height - halfHeight, halfHeight)))
    }

    private func drag(in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { dragOffset = $0.translation }
            .onEnded { _ in
                let end = center(in: bounds)
                dragOffset = .zero
                guard bounds.width > 0, bounds.height > 0 else { return }
                controller.position = CGPoint(x: end.x / bounds.width, y: end.y / bounds.height)
            }
    }

    // MARK: Colours

    private func color(_ level: PerformanceHUDReadout.Level) -> Color {
        switch level {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }

    private var borderColor: Color {
        switch controller.readout.level {
        case .normal: .secondary.opacity(0.4)
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Puts the `PerformanceHUDView` over the content while the HUD is on, and
/// measures only while the app is active.
struct PerformanceHUDOverlay: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            let controller = environment.performanceHUD
            if controller.isVisible {
                PerformanceHUDView(controller: controller)
                    .task(id: scenePhase == .active) {
                        guard scenePhase == .active else { return }
                        await controller.run()
                    }
            }
        }
    }
}

extension View {
    /// Overlays the debug performance HUD when it is on (see
    /// `PerformanceHUDController`).
    func performanceHUD() -> some View {
        modifier(PerformanceHUDOverlay())
    }
}

#Preview("Performance HUD") {
    let environment = AppEnvironment.preview(flags: [.perfHUD: true])
    Color.blue.opacity(0.2)
        .ignoresSafeArea()
        .performanceHUD()
        .appEnvironment(environment)
}
