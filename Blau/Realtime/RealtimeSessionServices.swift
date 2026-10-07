import BlauRealtime
import Foundation

/// Wires up the realtime session configuration (#35): the voice settings
/// Settings edits, and the configurator that turns them, with Blau's
/// instructions, into each `session.update`.
///
/// The turn orchestrator (#36) owns the `RealtimeClient`; it calls
/// `configurator.configure(client)` after every `.connected` and runs
/// `configurator.followSettingsChanges(sending: client)` for the session's
/// lifetime, so a voice or speed change in Settings goes out in the next
/// `session.update`.
@MainActor
final class RealtimeSessionServices {
    /// Settings → Voice binds to this.
    let voiceSettings: RealtimeVoiceSettingsModel
    /// Builds and sends `session.update`.
    let configurator: RealtimeSessionConfigurator

    init(
        persistence: any RealtimeVoiceSettingsPersisting,
        memory: any RealtimeMemoryContextProviding = NoRealtimeMemoryContext()
    ) {
        let store = RealtimeVoiceSettingsStore(persistence: persistence)
        voiceSettings = RealtimeVoiceSettingsModel(store: store)
        configurator = RealtimeSessionConfigurator(settings: store, memory: memory)
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
