#if DEBUG
    import BlauCore
    import BlauPersistence
    import SwiftUI

    /// The accessibility identifiers UI tests use for the debug menu.
    enum DebugMenuAccessibility {
        static let openButton = "blau.debugMenu.open"
        static let doneButton = "blau.debugMenu.done"
        static let resetAllButton = "blau.debugMenu.resetFlags"
    }

    /// Opens the debug menu. DEBUG builds only.
    struct DebugMenuButton: View {
        @State private var isPresented = false

        var body: some View {
            Button("Debug Menu", systemImage: "ladybug") {
                isPresented = true
            }
            .accessibilityIdentifier(DebugMenuAccessibility.openButton)
            .sheet(isPresented: $isPresented) {
                DebugMenuView()
            }
        }
    }

    /// Developer tools: feature flag overrides, the running configuration and
    /// the lifecycle state. DEBUG builds only.
    struct DebugMenuView: View {
        @Environment(AppEnvironment.self) private var environment
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    flagsSection
                    environmentSection
                    lifecycleSection
                    VoiceIDThresholdsSection(config: .calibrated)
                    modulesSection
                }
                .navigationTitle("Debug")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier(DebugMenuAccessibility.doneButton)
                    }
                }
            }
        }

        private var flagsSection: some View {
            Section {
                FeatureFlagToggles(flags: environment.flags)
                Button("Reset All Overrides", role: .destructive) {
                    environment.flags.resetOverrides()
                }
                .disabled(environment.flags.overriddenFlags.isEmpty)
                .accessibilityIdentifier(DebugMenuAccessibility.resetAllButton)
            } header: {
                Text("Feature flags")
            } footer: {
                Text(
                    "Overrides are stored on this device and apply to DEBUG builds only. "
                        + "Launch with -blau.featureFlag.<name> YES to override a flag for one run."
                )
            }
        }

        private var environmentSection: some View {
            Section("Environment") {
                LabeledContent("Services", value: environment.kind.rawValue)
                LabeledContent("Build", value: environment.config.environment.rawValue)
                LabeledContent("xAI host", value: environment.config.xaiAPIHost)
                LabeledContent("Realtime model", value: realtimeModelDescription)
                // Only whether a key exists; never the key.
                LabeledContent("Developer key", value: environment.config.hasDevelopmentAPIKey ? "Configured" : "None")
                LabeledContent("Store", value: storeDescription)
                if case .inMemory(.storeFailed(let failure)) = environment.persistence.stack?.mode {
                    Text("The on-disk store couldn't be opened: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }

        /// The model the realtime WebSocket actually connects to: the
        /// run-time override when one is set (#35), otherwise the pin.
        private var realtimeModelDescription: String {
            let config = environment.config
            guard config.xaiRealtimeModelOverride != nil else { return config.xaiRealtimeModel }
            return "\(config.effectiveRealtimeModel) (override)"
        }

        private var lifecycleSection: some View {
            Section("Lifecycle") {
                LabeledContent("Scene phase", value: environment.lifecycle.phase?.rawValue ?? "launching")
                LabeledContent("Phase changes", value: "\(environment.lifecycle.history.count)")
            }
        }

        private var modulesSection: some View {
            Section("BlauKit modules") {
                ForEach(BlauKitModules.all.map { ($0.name, $0.summary) }, id: \.0) { name, summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        private var storeDescription: String {
            guard let stack = environment.persistence.stack else { return "Opening" }
            switch stack.mode {
            case .cloudKit: return "\(stack.location.syncedStoreURL.lastPathComponent), iCloud"
            case .localOnly: return "\(stack.location.syncedStoreURL.lastPathComponent), on device"
            case .inMemory: return "In memory"
            }
        }
    }

    #Preview("Debug menu") {
        DebugMenuView()
            .appEnvironment(.preview(flags: [.perfHUD: true, .memoryTools: false]))
    }
#endif
