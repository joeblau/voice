import BlauRealtime
import Foundation
import Testing

@testable import Blau

/// The app's wiring of function calling (#38): Settings → Search and the
/// tool registry reach `session.tools`, and the runner answers calls.
@Suite("Search and tools in the app")
@MainActor
struct SearchToolsAppTests {
    @Test func searchTogglesReachTheNextSessionUpdate() async throws {
        let suite = "blau.tests.search.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let services = RealtimeSessionServices(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        #expect(services.toolRegistry.isEmpty)
        #expect(await services.configurator.currentSession().tools == nil)

        // What SearchToolsSettingsSection's toggles do.
        services.voiceSettings.setEnabled(.webSearch, true)
        services.voiceSettings.setEnabled(.xSearch, true)
        let tools = await services.configurator.currentSession().tools
        #expect(tools == [RealtimeBuiltInTool.webSearch.definition, RealtimeBuiltInTool.xSearch.definition])

        // A relaunch keeps them.
        let relaunched = RealtimeSessionServices(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        #expect(relaunched.voiceSettings.builtInTools == [.webSearch, .xSearch])
        #expect(SearchToolsSettingsIdentifiers.toggle(.webSearch) == "settings.search.web_search")
    }

    @Test func registeredToolsAreDeclaredAndRun() async throws {
        let services = RealtimeSessionServices(
            persistence: InMemoryVoiceSettingsPersistence(), tools: try RealtimeToolRegistry([EchoTool()]))
        #expect(await services.configurator.currentSession().tools == [EchoTool.definition])

        let sender = SentEvents()
        let runner = services.makeToolRunner(sender: sender)
        await runner.handle(
            .responseFunctionCallArgumentsDone(
                .init(responseID: "resp_1", callID: "call_1", name: "echo", arguments: #"{"text":"hi"}"#)))
        await runner.handle(.responseDone(.init(response: RealtimeResponse(id: "resp_1", status: .completed))))
        var waited = 0
        while await sender.events.count < 2, waited < 1_000 {
            try await Task.sleep(for: .milliseconds(2))
            waited += 1
        }
        #expect(
            await sender.events == [
                .conversationItemCreate(.functionOutput(callID: "call_1", output: #"{"text":"hi"}"#)),
                .responseCreate(),
            ])
    }
}

private actor SentEvents: RealtimeEventSending {
    private(set) var events: [RealtimeClientEvent] = []

    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        events.append(event)
    }
}
