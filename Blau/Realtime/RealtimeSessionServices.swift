import BlauRealtime
import Foundation

/// Wires up the realtime session configuration (#35): the voice settings
/// Settings edits, and the configurator that turns them, with Blau's
/// instructions, into each `session.update`; and function calling (#38):
/// the tools Grok can call and the runner that answers them.
///
/// The turn orchestrator (#36) owns the `RealtimeClient`; it calls
/// `configurator.configure(client)` after every `.connected` and runs
/// `configurator.followSettingsChanges(sending: client)` for the session's
/// lifetime, so a voice, speed or search change in Settings goes out in the
/// next `session.update`. It makes one runner with
/// `makeToolRunner(sender: client)`, passes it every server event
/// (`runner.handle(event)`), and calls `runner.cancelAll()` on barge-in and
/// on each new connection.
@MainActor
final class RealtimeSessionServices {
    /// Settings → Voice and Settings → Search bind to this.
    let voiceSettings: RealtimeVoiceSettingsModel
    /// Builds and sends `session.update`.
    let configurator: RealtimeSessionConfigurator
    /// The client-side tools declared in `session.tools`. Empty until the
    /// memory tools (#68) register here, behind the `memoryTools` flag.
    let toolRegistry: RealtimeToolRegistry

    init(
        persistence: any RealtimeVoiceSettingsPersisting,
        memory: any RealtimeMemoryContextProviding = NoRealtimeMemoryContext(),
        tools: RealtimeToolRegistry = RealtimeToolRegistry()
    ) {
        let store = RealtimeVoiceSettingsStore(persistence: persistence)
        voiceSettings = RealtimeVoiceSettingsModel(store: store)
        toolRegistry = tools
        configurator = RealtimeSessionConfigurator(settings: store, memory: memory, tools: tools.definitions)
    }

    /// A runner that answers the function calls of the session `sender`
    /// (the `RealtimeClient`) carries, from ``toolRegistry``.
    func makeToolRunner(sender: any RealtimeEventSending) -> RealtimeToolRunner {
        RealtimeToolRunner(registry: toolRegistry, sender: sender)
    }

    /// The app's services. Settings live in `UserDefaults`; DEBUG UI-test
    /// runs use a separate suite so they never change the developer's own
    /// settings.
    static func make() -> RealtimeSessionServices {
        #if DEBUG
            if XAIUITestStub.current != nil {
                return RealtimeSessionServices(
                    persistence: UserDefaultsVoiceSettingsPersistence(suiteName: "blau.uitests"))
            }
        #endif
        return RealtimeSessionServices(persistence: UserDefaultsVoiceSettingsPersistence())
    }
}
