import BlauCore
import SwiftUI

/// One toggle per `FeatureFlag`, with its summary and whether it is
/// overridden. Used by the DEBUG menu, and meant for Settings → Developer
/// (#43). When the flags don't allow overrides (release builds), the toggles
/// show the shipping values and are disabled.
struct FeatureFlagToggles: View {
    let flags: FeatureFlags

    var body: some View {
        ForEach(FeatureFlag.allCases) { flag in
            FeatureFlagRow(flag: flag, flags: flags)
        }
    }
}

/// The accessibility identifiers UI tests use for the flag rows.
enum FeatureFlagAccessibility {
    static func toggleIdentifier(_ flag: FeatureFlag) -> String { "blau.flag.\(flag.rawValue)" }
    static func resetIdentifier(_ flag: FeatureFlag) -> String { "blau.flag.\(flag.rawValue).reset" }
}

private struct FeatureFlagRow: View {
    let flag: FeatureFlag
    let flags: FeatureFlags

    private var isOn: Binding<Bool> {
        Binding(
            get: { flags.isEnabled(flag) },
            set: { flags.setOverride($0, for: flag) }
        )
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.title)
                Text(flag.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(flags.isOverridden(flag) ? .orange : .secondary)
            }
        }
        .accessibilityIdentifier(FeatureFlagAccessibility.toggleIdentifier(flag))
        .disabled(!flags.allowsOverrides)
        .swipeActions {
            if flags.isOverridden(flag) {
                resetButton
            }
        }
        .contextMenu {
            if flags.isOverridden(flag) {
                resetButton
            }
        }
    }

    private var status: String {
        let defaultText = flag.defaultValue ? "on" : "off"
        return flags.isOverridden(flag) ? "Overridden · default \(defaultText)" : "Default (\(defaultText))"
    }

    private var resetButton: some View {
        Button("Reset to Default", systemImage: "arrow.uturn.backward") {
            flags.setOverride(nil, for: flag)
        }
        .accessibilityIdentifier(FeatureFlagAccessibility.resetIdentifier(flag))
    }
}

#Preview {
    Form {
        Section("Feature flags") {
            FeatureFlagToggles(flags: .inMemory([.perfHUD: true]))
        }
        Section("Release build") {
            FeatureFlagToggles(flags: FeatureFlags(storage: InMemoryFeatureFlagStorage(), allowsOverrides: false))
        }
    }
}
