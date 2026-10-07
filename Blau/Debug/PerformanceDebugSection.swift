#if DEBUG
    import BlauTelemetry
    import SwiftUI

    /// The accessibility identifiers UI tests use for the performance
    /// section.
    enum PerformanceDebugAccessibility {
        static let levelPicker = "blau.debugMenu.performanceLevel"
        static let currentLevel = "blau.debugMenu.performanceLevel.current"
    }

    /// The thermal and power policy in the debug menu (#75): the readings,
    /// the level and why, and an override to try each level on a device
    /// that is cool and plugged in (or in the simulator, which always reads
    /// nominal and has no battery).
    struct PerformanceDebugSection: View {
        let policy: PerformancePolicy
        @Environment(PerformanceStatus.self) private var status

        var body: some View {
            Section {
                LabeledContent("Level", value: status.snapshot.level.rawValue)
                    .accessibilityIdentifier(PerformanceDebugAccessibility.currentLevel)
                LabeledContent("Why", value: reasons)
                LabeledContent("Thermal state", value: conditions.thermalState.rawValue)
                LabeledContent("Low Power Mode", value: conditions.isLowPowerModeEnabled ? "On" : "Off")
                LabeledContent("Battery", value: battery)
                Picker("Override", selection: override) {
                    Text("Automatic").tag(PerformanceLevel?.none)
                    ForEach(PerformanceLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(PerformanceLevel?.some(level))
                    }
                }
                .accessibilityIdentifier(PerformanceDebugAccessibility.levelPicker)
            } header: {
                Text("Thermal and power")
            } footer: {
                Text(
                    "Normal: everything on. Reduced: 1280 ms ASR chunks, no second pass, topic confirmation "
                        + "for strong candidates only, indexing deferred. Minimal: Apple's transcriber where "
                        + "available, no topic confirmation, indexing suspended."
                )
            }
        }

        private var conditions: DeviceConditions { status.snapshot.conditions }

        private var reasons: String {
            let snapshot = status.snapshot
            guard snapshot.level.isDegraded else { return "Conditions allow everything" }
            let causes = snapshot.reasons.map(\.description).joined(separator: ", ")
            return snapshot.isRecovering ? "\(causes) (recovering)" : causes
        }

        private var battery: String {
            let battery = conditions.battery
            guard let percent = battery.percent else { return "Unknown" }
            return "\(percent)% (\(battery.state.rawValue))"
        }

        private var override: Binding<PerformanceLevel?> {
            Binding(
                get: { status.snapshot.override },
                set: { policy.setOverride($0) }
            )
        }
    }
#endif
