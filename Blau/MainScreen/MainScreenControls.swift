import SwiftUI

/// The accessibility identifiers UI tests use for the main screen.
enum MainScreenAccessibility {
    /// The scrolling content area (the conversation, #42).
    static let content = RootView.accessibilityIdentifier
    /// What the content area shows before there is a conversation.
    static let emptyState = "blau.mainScreen.empty"
    /// The settings button, bottom-left. Kept equal to the identifier the
    /// xAI and iCloud UI tests already use.
    static let settingsButton = XAIKeyIdentifiers.openSettings
    /// The record button, bottom-right.
    static let recordButton = "blau.record"
}

/// Opens Settings. Lives in the leading slot of the main screen's bottom bar.
struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Settings", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier(MainScreenAccessibility.settingsButton)
        .accessibilityShowsLargeContentViewer()
    }
}

/// Starts and stops recording. Lives in the trailing slot of the main
/// screen's bottom bar, styled as the bar's prominent (tinted glass) control.
///
/// This is the scaffold's version: idle shows a microphone, recording shows a
/// stop glyph, and a spinner covers the moment between. The record button
/// issue (#41) adds the session states, the level ring and haptics.
struct RecordButton: View {
    let phase: RecordingController.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .brandProminentButtonStyle(phase == .recording || phase == .stopping ? .recordingFill : .accentFill)
        .disabled(phase.isBusy)
        .accessibilityIdentifier(MainScreenAccessibility.recordButton)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private var label: some View {
        if phase.isBusy {
            ProgressView()
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }

    private var title: LocalizedStringKey {
        switch phase {
        case .idle, .starting: "Record"
        case .recording, .stopping: "Stop Recording"
        }
    }

    private var systemImage: String {
        switch phase {
        case .idle, .starting: "mic.fill"
        case .recording, .stopping: "stop.fill"
        }
    }

    private var accessibilityValue: Text {
        switch phase {
        case .idle: Text("Not recording")
        case .starting: Text("Starting")
        case .recording: Text("Recording")
        case .stopping: Text("Stopping")
        }
    }

    private var accessibilityHint: Text {
        switch phase {
        case .idle: Text("Starts a conversation")
        case .recording: Text("Ends the conversation")
        case .starting, .stopping: Text("")
        }
    }
}

#Preview("Controls") {
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SettingsButton {}
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    RecordButton(phase: .idle) {}
                }
            }
    }
}

#Preview("Recording") {
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SettingsButton {}
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    RecordButton(phase: .recording) {}
                }
            }
    }
}
