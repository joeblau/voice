import BlauRealtime
import SwiftUI

/// Accessibility identifiers for Settings → Search, shared with UI tests.
enum SearchToolsSettingsIdentifiers {
    static func toggle(_ tool: RealtimeBuiltInTool) -> String {
        "settings.search.\(tool.rawValue)"
    }
}

/// Settings → Search: whether Grok may search the web and X while you talk
/// (xAI's built-in `web_search` and `x_search` tools, #38). Off by default.
/// A change is saved at once and sent to a live session with the next
/// `session.update`, like the voice settings.
struct SearchToolsSettingsSection: View {
    @Environment(RealtimeVoiceSettingsModel.self) private var model

    var body: some View {
        Section {
            ForEach(RealtimeBuiltInTool.available) { tool in
                Toggle(
                    tool.displayName,
                    isOn: Binding(
                        get: { model.isEnabled(tool) },
                        set: { model.setEnabled(tool, $0) }
                    )
                )
                .accessibilityIdentifier(SearchToolsSettingsIdentifiers.toggle(tool))
            }
        } header: {
            Text("Search")
        } footer: {
            Text(
                "Lets Grok look things up on the web or on X when it helps answer you. Searches run at xAI "
                    + "and may add to your xAI usage."
            )
        }
    }
}

#if DEBUG
    #Preview {
        Form {
            SearchToolsSettingsSection()
        }
        .environment(RealtimeVoiceSettingsModel.preview(RealtimeVoiceSettings(builtInTools: [.webSearch])))
    }
#endif
