import BlauRealtime
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
    /// "You're muted", shown above the record button when the user talks
    /// while listening is paused.
    static let mutedHint = "blau.record.mutedHint"
    /// The hint's Resume button.
    static let mutedHintResume = "blau.record.mutedHint.resume"
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

#Preview("Controls") {
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SettingsButton {}
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    RecordButton(model: RecordButtonModel(session: FakeConversationSession()))
                }
            }
    }
}

#Preview("Listening") {
    let session = FakeConversationSession()
    session.update(.listening)
    return NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SettingsButton {}
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    RecordButton(model: RecordButtonModel(session: session))
                }
            }
    }
}
