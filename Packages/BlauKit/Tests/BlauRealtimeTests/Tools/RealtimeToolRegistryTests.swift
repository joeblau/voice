import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

/// Encodes `value` the way `RealtimeEventCoding` does and returns the text.
private func wire(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private struct NoArgumentsTool: RealtimeTypedFunctionTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "now"
    static let description = "No arguments."
    static let parameters = JSONSchema.noArguments
    func call(arguments: Arguments) async throws -> String { #"{"ok":true}"# }
}

private struct BadNameTool: RealtimeFunctionTool {
    static let name = "search memory"
    static let description = ""
    static let parameters = JSONSchema.noArguments
    func call(_ arguments: Data) async throws -> String { "" }
}

@Suite("Tool registry")
struct RealtimeToolRegistryTests {
    @Test func contributesFlatFunctionDefinitionsToSessionTools() throws {
        let registry = try RealtimeToolRegistry([EchoTool()])
        #expect(registry.names == ["echo"])
        #expect(
            try wire(registry.definitions) == """
                [{"description":"Repeats the given text back exactly. Use it only when the user asks you to test the echo tool.",\
                "name":"echo","parameters":{"additionalProperties":false,"properties":{"text":{"description":"The text to repeat.",\
                "type":"string"}},"required":["text"],"type":"object"},"type":"function"}]
                """)
    }

    @Test func refusesDuplicateAndMalformedNames() throws {
        var registry = RealtimeToolRegistry()
        try registry.register(EchoTool())
        #expect(throws: RealtimeToolRegistry.RegistrationError.duplicateName("echo")) {
            try registry.register(EchoTool())
        }
        #expect(throws: RealtimeToolRegistry.RegistrationError.invalidName("search memory")) {
            try registry.register(BadNameTool())
        }
        #expect(registry.names == ["echo"])
        registry.unregister(named: "echo")
        #expect(registry.isEmpty)
    }

    @Test(arguments: [
        ("search_memory", true), ("get-entity", true), ("A1", true), (String(repeating: "a", count: 64), true),
        ("", false), (String(repeating: "a", count: 65), false), ("has space", false), ("dot.name", false),
        ("émoji", false),
    ])
    func validatesNames(name: String, isValid: Bool) {
        #expect(RealtimeToolRegistry.isValidName(name) == isValid)
    }

    @Test func looksToolsUpByName() throws {
        let registry = try RealtimeToolRegistry([EchoTool(), NoArgumentsTool()])
        #expect(registry.tool(named: "now") is NoArgumentsTool)
        #expect(registry.tool(named: "nope") == nil)
        #expect(registry.definitions.map(\.guidanceName) == ["echo", "now"])
    }
}

@Suite("Function tools")
struct RealtimeFunctionToolTests {
    @Test func echoReturnsItsText() async throws {
        let output = try await EchoTool().call(Data(#"{"text": "blue \"harbor\" / ✓"}"#.utf8))
        #expect(output == #"{"text":"blue \"harbor\" / ✓"}"#)
    }

    @Test func typedToolsRejectArgumentsThatDontMatch() async {
        await #expect(throws: RealtimeToolError.invalidArguments("missing key text at <root>")) {
            try await EchoTool().call(Data(#"{"words": "x"}"#.utf8))
        }
        await #expect(throws: RealtimeToolError.self) {
            try await EchoTool().call(Data("not json".utf8))
        }
    }

    @Test(arguments: ["", "  ", "{}"])
    func typedToolsWithoutParametersAcceptEmptyArguments(arguments: String) async throws {
        #expect(try await NoArgumentsTool().call(Data(arguments.utf8)) == #"{"ok":true}"#)
    }

    @Test func errorOutputIsAJSONObject() throws {
        let output = RealtimeToolOutput.error("timeout", message: "Too \"slow\".")
        #expect(try outputObject(output) == ["error": "timeout", "message": "Too \"slow\"."])
    }

    @Test func defaultTimeoutIsThreeSeconds() {
        #expect(RealtimeToolRunner.Configuration.defaultTimeout == .seconds(3))
        #expect(EchoTool.timeout == .seconds(3))
    }
}

@Suite("JSON Schema")
struct JSONSchemaTests {
    @Test func buildsEveryKind() throws {
        let schema = JSONSchema.object(
            properties: [
                "query": .string(description: "What to find."),
                "kind": .string(enum: ["fact", "note"]),
                "limit": .integer(minimum: 1, maximum: 10),
                "score": .number(minimum: 0, maximum: 1),
                "exact": .boolean(),
                "tags": .array(of: .string(), maximumCount: 5),
            ],
            required: ["query", "limit"],
            description: "A search.",
            additionalProperties: false)
        #expect(
            try wire(schema) == """
                {"additionalProperties":false,"description":"A search.","properties":{"exact":{"type":"boolean"},\
                "kind":{"enum":["fact","note"],"type":"string"},"limit":{"maximum":10,"minimum":1,"type":"integer"},\
                "query":{"description":"What to find.","type":"string"},"score":{"maximum":1,"minimum":0,"type":"number"},\
                "tags":{"items":{"type":"string"},"maxItems":5,"type":"array"}},"required":["query","limit"],"type":"object"}
                """)
    }

    @Test func noArgumentsIsAnEmptyObject() throws {
        #expect(try wire(JSONSchema.noArguments) == #"{"properties":{},"type":"object"}"#)
    }

    @Test func roundTripsAndWrapsHandWrittenSchemas() throws {
        let schema = JSONSchema(json: ["type": "object", "properties": ["q": ["type": "string"]]])
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: Data(try wire(schema).utf8))
        #expect(decoded == schema)
    }
}

@Suite("Built-in tools")
struct RealtimeBuiltInToolTests {
    @Test func areSentWithXAIsDefaults() throws {
        #expect(try wire([RealtimeBuiltInTool.webSearch.definition]) == #"[{"type":"web_search"}]"#)
        #expect(try wire([RealtimeBuiltInTool.xSearch.definition]) == #"[{"type":"x_search"}]"#)
        #expect(RealtimeBuiltInTool.available == [.webSearch, .xSearch])
        #expect(RealtimeBuiltInTool.webSearch.displayName == "Web Search")
        #expect(RealtimeBuiltInTool.xSearch.displayName == "X Search")
    }

    @Test func settingsKeepThemInAFixedOrderAndDropUnsupportedOnes() {
        var settings = RealtimeVoiceSettings(builtInTools: [.xSearch, .webSearch, "file_search"])
        #expect(settings.builtInTools == [.webSearch, .xSearch])
        #expect(
            settings.builtInToolDefinitions == [
                RealtimeBuiltInTool.webSearch.definition, RealtimeBuiltInTool.xSearch.definition,
            ])
        settings.builtInTools.insert("mcp")
        #expect(settings.builtInTools == [.webSearch, .xSearch])
        #expect(RealtimeVoiceSettings.default.builtInTools.isEmpty)
    }

    @Test func settingsPersistThemAndOlderSettingsStillLoad() throws {
        let settings = RealtimeVoiceSettings(voice: .ara, builtInTools: [.xSearch, .webSearch])
        let json = try wire(settings)
        #expect(json.contains(#""built_in_tools":["web_search","x_search"]"#))
        #expect(try JSONDecoder().decode(RealtimeVoiceSettings.self, from: Data(json.utf8)) == settings)

        let older = #"{"voice":"rex","speed":1.1,"reasoning_effort":"high"}"#
        let loaded = try JSONDecoder().decode(RealtimeVoiceSettings.self, from: Data(older.utf8))
        #expect(loaded.voice == .rex)
        #expect(loaded.builtInTools.isEmpty)
    }

    @Test func sessionUpdateCarriesFunctionToolsThenTheBuiltInOnes() throws {
        let registry = try RealtimeToolRegistry([EchoTool()])
        let session = RealtimeSessionConfiguration.blau.session(
            settings: RealtimeVoiceSettings(builtInTools: [.webSearch]), tools: registry.definitions,
            now: SessionFixtures.now, timeZone: SessionFixtures.timeZone)
        #expect(session.tools == [EchoTool.definition, RealtimeBuiltInTool.webSearch.definition])
        #expect(session.instructions?.contains("You can use these tools: echo, web_search.") == true)
        #expect(session.instructions?.contains("let me check") == true)

        let none = RealtimeSessionConfiguration.blau.session(
            settings: .default, now: SessionFixtures.now, timeZone: SessionFixtures.timeZone)
        #expect(none.tools == nil)
        #expect(none.instructions?.contains("# Tools") == false)
    }

    /// Turning a search tool on in Settings reaches the live session with
    /// the next (debounced) `session.update`, like a voice change.
    @Test func turningOneOnSendsASessionUpdate() async throws {
        let clock = ManualClock(now: SessionFixtures.now)
        let store = RealtimeVoiceSettingsStore()
        let configurator = RealtimeSessionConfigurator(
            settings: store, tools: [EchoTool.definition], clock: clock, timeZone: { SessionFixtures.timeZone })
        let sender = RecordingSender()
        try await configurator.configure(sender)
        #expect(sender.sessions.last?.tools == [EchoTool.definition])

        let following = Task { await configurator.followSettingsChanges(sending: sender) }
        defer { following.cancel() }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }
        store.update { $0.builtInTools.insert(.xSearch) }
        try await waitUntil("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(400))
        try await waitUntil("second update") { sender.sessions.count == 2 }
        #expect(sender.sessions.last?.tools == [EchoTool.definition, RealtimeBuiltInTool.xSearch.definition])
    }

    @Test @MainActor func settingsModelTogglesThem() {
        let store = RealtimeVoiceSettingsStore()
        let model = RealtimeVoiceSettingsModel(store: store)
        #expect(!model.isEnabled(.webSearch))
        model.setEnabled(.webSearch, true)
        #expect(model.isEnabled(.webSearch))
        #expect(store.settings.builtInTools == [.webSearch])
        model.setEnabled(.webSearch, false)
        #expect(store.settings.builtInTools.isEmpty)
        model.builtInTools = [.xSearch]
        #expect(store.settings.builtInTools == [.xSearch])
    }
}
