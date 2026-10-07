import BlauTelemetry
import Observation
import SwiftUI

/// The thermal and power policy's state for the views (#75): the latest
/// `PerformanceSnapshot`, kept up to date on the main actor.
@MainActor
@Observable
final class PerformanceStatus {
    private(set) var snapshot: PerformanceSnapshot
    @ObservationIgnored private let policy: PerformancePolicy
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(policy: PerformancePolicy) {
        self.policy = policy
        snapshot = policy.snapshot
    }

    /// Follows the policy. Calling it again does nothing.
    func start() {
        guard updates == nil else { return }
        let stream = policy.updates()
        updates = Task { [weak self] in
            for await snapshot in stream {
                self?.snapshot = snapshot
            }
        }
    }

    /// What the indicator shows, or `nil` while everything runs normally.
    var indicator: PerformanceIndicatorContent? { PerformanceIndicatorContent(snapshot) }
}

/// The text and symbol of the degraded-mode indicator: a subtle note that
/// Blau is saving work, and why.
struct PerformanceIndicatorContent: Equatable {
    /// Short, e.g. "Cooling down".
    let title: String
    /// SF Symbol name.
    let systemImage: String
    /// What VoiceOver reads: the cause and what changes.
    let accessibilityLabel: String

    /// `nil` at `normal`: there is nothing to show.
    init?(_ snapshot: PerformanceSnapshot) {
        guard snapshot.level.isDegraded else { return nil }
        let effect =
            snapshot.level == .minimal
            ? String(localized: "Transcription is simplified and background work is paused.")
            : String(localized: "Live captions update less often and extra processing is paused.")
        switch snapshot.reasons.first {
        case .thermal?:
            title = String(localized: "Cooling down")
            systemImage = "thermometer.medium"
            accessibilityLabel = String(localized: "Your iPhone is warm, so Blau is saving work. \(effect)")
        case .lowBattery(let percent)?:
            title = String(localized: "Saving battery")
            systemImage = "battery.25percent"
            accessibilityLabel = String(
                localized: "Battery at \(percent) percent, so Blau is saving work. \(effect)")
        case .lowPowerMode?:
            title = String(localized: "Low Power Mode")
            systemImage = "leaf"
            accessibilityLabel = String(localized: "Low Power Mode is on, so Blau is saving work. \(effect)")
        case .override?, nil:
            title = String(localized: "Saving power")
            systemImage = "gauge.with.dots.needle.33percent"
            accessibilityLabel = String(localized: "Blau is saving work. \(effect)")
        }
    }
}

/// A small, quiet capsule at the top of the main screen while the
/// pipeline runs below `normal` (#75). Hidden otherwise.
struct PerformanceIndicator: View {
    nonisolated static let accessibilityIdentifier = "blau.performance.indicator"

    @Environment(PerformanceStatus.self) private var status

    var body: some View {
        Group {
            if let content = status.indicator {
                Label(content.title, systemImage: content.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(content.accessibilityLabel)
                    .accessibilityIdentifier(Self.accessibilityIdentifier)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: status.indicator)
    }
}

#Preview("Degraded") {
    let policy = PerformancePolicy(source: ManualDeviceConditionsSource(DeviceConditions(thermalState: .serious)))
    policy.update(DeviceConditions(thermalState: .serious))
    let status = PerformanceStatus(policy: policy)
    return PerformanceIndicator()
        .environment(status)
        .padding()
}
