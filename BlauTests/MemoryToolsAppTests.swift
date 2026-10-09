import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import Foundation
import SwiftData
import Testing

@testable import Blau

/// How the app wires Grok's memory tools (#68): the live composition root
/// declares them in `session.tools` behind the `memoryTools` flag, the turn
/// orchestrator runs them, and they read the store the app has open.
@Suite("Memory tools in the app")
@MainActor
struct MemoryToolsAppTests {
    private func live(memoryTools: Bool?) throws -> (AppEnvironment, UserDefaults, String) {
        let suite = "com.joeblau.blau.tests.memorytools.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let memoryTools {
            defaults.set(memoryTools, forKey: FeatureFlag.memoryTools.defaultsKey)
        }
        let environment = AppEnvironment.live(config: .fallback, defaults: defaults, persistence: .inMemory())
        return (environment, defaults, suite)
    }

    @Test func theLiveSessionDeclaresAndRunsTheMemoryTools() async throws {
        let (environment, defaults, suite) = try live(memoryTools: nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        // #69: the practice tools follow the memory tools, on the same flag.
        #expect(environment.realtimeSession.toolRegistry.names == MemoryTools.names + PracticeTools.names)
        let declared = await environment.realtimeSession.configurator.currentSession().tools ?? []
        #expect(declared.contains(SearchMemoryTool.definition))
        #expect(declared.contains(ForgetTool.definition))
        // The orchestrator owns the runner over the same tools.
        let orchestrator = try #require(environment.realtime as? TurnOrchestrator)
        let runner = try #require(orchestrator.toolRunner)
        #expect(await runner.registry.names == MemoryTools.names + PracticeTools.names)
        #expect(orchestrator.configuration.keepsToolPayloads == AppConfig.isDebugBuild)
    }

    @Test func theFlagTurnsThemOff() async throws {
        // Overrides are honoured in Debug builds, which tests run.
        guard AppConfig.isDebugBuild else { return }
        let (environment, defaults, suite) = try live(memoryTools: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(environment.realtimeSession.toolRegistry.isEmpty)
        #expect(await environment.realtimeSession.configurator.currentSession().tools == nil)
        #expect((environment.realtime as? TurnOrchestrator)?.toolRunner == nil)
    }

    /// The acceptance question against the app's own wiring: the company
    /// document in the open store answers it, before any index exists.
    @Test func theToolsReadTheStoreTheAppHasOpen() async throws {
        let (environment, defaults, suite) = try live(memoryTools: nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        await environment.persistence.start()
        #expect(await environment.memoryIndexing.performBackgroundWork())
        let container = try #require(environment.modelContainer)
        container.mainContext.insert(
            MemoryDocument(
                kind: .company, title: "Larderly", body: "Inventory and food-cost app for independent restaurants.",
                createdAt: Date()))
        try container.mainContext.save()

        let search = try #require(environment.realtimeSession.toolRegistry.tool(named: SearchMemoryTool.name))
        let output = try await search.call(Data(#"{"query":"what my company does","kinds":["company"]}"#.utf8))
        #expect(output.contains("Company · Larderly"))
        #expect(output.contains("independent restaurants"))
        environment.memoryIndexing.stop()
    }
}
