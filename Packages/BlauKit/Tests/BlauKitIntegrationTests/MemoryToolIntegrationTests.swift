import BlauAudio
import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import SwiftData
import Synchronization
import Testing

/// Grok's memory tools (BlauRealtime, #68) over BlauMemory's backend, wired
/// as the app's composition root wires them: a real SwiftData store, the
/// search index built from it, `MemoryToolService`, the tools, and the turn
/// orchestrator running them inside a replayed realtime session.
@Suite("Memory tools: integration")
struct MemoryToolIntegrationTests {
    static let t0 = Date(timeIntervalSince1970: 1_768_478_400)

    // MARK: - Fixtures

    /// A deterministic lexical embedder (each word adds ±1 to a hashed
    /// component), standing in for the shared embedding model.
    struct HashingEmbedder: MemoryChunkEmbedding, MemoryQueryEmbedding {
        static let version = "hashing-256d-int8@1"

        func currentModelVersion() async throws -> String { Self.version }

        func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
            texts.map(Self.embed)
        }

        func embedQuery(_ text: String) async throws -> TextEmbedding {
            Self.embed(text)
        }

        static func embed(_ text: String) -> TextEmbedding {
            var vector = [Float](repeating: 0, count: 256)
            for word in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for byte in word.utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x100_0000_01b3
                }
                vector[Int(hash % 256)] += (hash >> 32) & 1 == 0 ? 1 : -1
            }
            return TextEmbedding(
                fullOutput: vector, dimensions: 256, modelVersion: version, tokenCount: 0, truncatedTokens: 0)
        }
    }

    /// A store with the user's knowledge base and `notes` filler notes, its
    /// index, and the memory backend over both.
    struct Memory {
        let container: ModelContainer
        let index: MemoryIndex
        let service: MemoryToolService
        let companyID: UUID

        init(notes: Int = 0, embedder: HashingEmbedder? = HashingEmbedder()) async throws {
            container = try BlauModelContainer.makeInMemory()
            companyID = try await Self.populate(container, notes: notes)
            index = try MemoryIndex.inMemory()
            try await MemoryIndexRebuilder(
                index: index, sources: SwiftDataMemorySources(container: container), embedder: embedder
            ).rebuild()
            service = MemoryToolService(
                MemoryToolService.Context(container: container, index: index), embedder: embedder,
                chunkEmbedder: embedder)
        }

        @MainActor
        static func populate(_ container: ModelContainer, notes: Int) throws -> UUID {
            let context = container.mainContext
            let company = MemoryDocument(
                kind: .company, title: "Larderly",
                body: """
                    # Product
                    Inventory and food-cost app for independent restaurants.

                    # Pricing
                    $149 per location per month.
                    """,
                createdAt: MemoryToolIntegrationTests.t0)
            context.insert(company)
            context.insert(
                MemoryDocument(
                    kind: .profile, title: "About me", body: "Former line cook, now a founder in Oakland.",
                    createdAt: MemoryToolIntegrationTests.t0))
            let words = [
                "harbor", "ledger", "orchard", "lantern", "meadow", "copper", "willow", "granite", "saffron", "tundra",
                "violet", "marble", "falcon", "juniper", "quartz", "cobalt", "ember", "fennel", "glacier", "hazel",
            ]
            for number in 0..<notes {
                let topic = (0..<6).map { words[(number * 7 + $0 * 3) % words.count] }.joined(separator: " ")
                context.insert(
                    MemoryDocument(
                        kind: .note, title: "Note \(number)",
                        body: """
                            # Ideas
                            \(topic) planning notes number \(number) about suppliers, menus and staffing.

                            # Follow-ups
                            Call the \(words[number % words.count]) team about the \(words[(number + 5) % words.count]) order.

                            # Numbers
                            Week \(number % 52): covers \(100 + number % 300), food cost \(28 + number % 9) percent.
                            """,
                        createdAt: MemoryToolIntegrationTests.t0.addingTimeInterval(Double(number) * 3_600)))
            }
            try context.save()
            return company.id
        }
    }

    final class SilentAudioOutput: AgentAudioOutput {
        func enqueue(pcm16 bytes: Data, item: PlaybackItemID) -> EnqueueResult { .queued }
        func finish(_ item: PlaybackItemID) {}
        func flush() -> PlaybackFlushResult { PlaybackFlushResult(interrupted: [], droppedDuration: .zero) }
        func playedItem(for item: PlaybackItemID) -> PlayedItem? { nil }
        func waitUntilIdle() async {}
    }

    struct StaticTokenProvider: RealtimeTokenProviding {
        func clientSecret() async throws -> RealtimeClientSecret {
            RealtimeClientSecret(value: "test-secret", expiresAt: nil)
        }

        func invalidate() async {}
    }

    static func waitUntil(
        _ what: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - "What does my company do?"

    /// Acceptance criterion: "What does my company do?" is answered from the
    /// knowledge base. The hand-written `memory-tool` session (Grok speaks a
    /// filler, calls `search_memory` with `kinds: ["company"]`, then answers)
    /// replayed in lockstep through a real client and the turn orchestrator,
    /// with the real tools over the real store: the output Grok gets is the
    /// company document, and the answer is stored after the filler.
    ///
    /// Without an embedding model (a fresh install), the question shares no
    /// word with the document, so this also covers the store fallback.
    @Test(arguments: [true, false])
    func whatDoesMyCompanyDoIsAnsweredFromTheKnowledgeBase(withVectors: Bool) async throws {
        let memory = try await Memory(embedder: withVectors ? HashingEmbedder() : nil)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../BlauRealtimeTests/Fixtures/memory-tool.jsonl").standardized
        let connector = RealtimeReplayConnector(transcript: try RealtimeTranscript(contentsOf: fixture))
        let clock = ManualClock(now: Self.t0.addingTimeInterval(86_400))
        let client = RealtimeClient(
            endpoint: URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")!,
            tokenProvider: StaticTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let store = ConversationStore(modelContainer: memory.container, savePolicy: .immediate)
        let tools = try RealtimeToolRegistry(
            MemoryTools.all(
                backend: memory.service,
                settings: MemoryToolSettings(timeZone: { TimeZone(identifier: "UTC")! }, clock: clock)))
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(
                settings: RealtimeVoiceSettingsStore(), tools: tools.definitions, clock: clock),
            audio: SilentAudioOutput(), transcript: store, tools: tools, clock: clock, signposter: .disabled(.realtime),
            configuration: .init(keepsToolPayloads: true))

        try await orchestrator.start()
        try await orchestrator.send(
            Utterance(
                conversationID: ConversationID(), speaker: .user, text: "What does my company do?",
                timeRange: TimeRange(start: .zero, duration: .seconds(2)), startedAt: clock.now))
        try await Self.waitUntil("the answer") { await orchestrator.snapshot.completedTurns == 1 }
        try await Self.waitUntil("listening") { await orchestrator.state == .listening }
        await orchestrator.waitUntilSettled()

        // Every frame lines up with the fixture: the tool's output, then
        // exactly one follow-up.
        let sent = try #require(connector.sockets.first).sentEvents
        #expect(
            sent.map(\.type) == [
                "session.update", "conversation.item.create", "response.create", "conversation.item.create",
                "response.create",
            ])
        guard case .conversationItemCreate(.functionCallOutput(let output), _) = sent[3] else {
            Issue.record("Expected the function_call_output")
            return
        }
        #expect(output.callID == "call_memory_001")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.output.utf8)) as? [String: Any])
        let results = try #require(object["results"] as? [[String: Any]])
        let first = try #require(results.first)
        #expect(first["kind"] as? String == "company")
        #expect(first["source"] as? String == "Company · Larderly")
        #expect((first["text"] as? String)?.contains("Inventory and food-cost app for independent restaurants") == true)
        #expect(results.allSatisfy { $0["kind"] as? String == "company" })
        #expect(MemoryToolSettings.approximateTokens(output.output) <= 1_500)

        // The conversation as stored: the question, the filler, the answer.
        let rows = try #require(try ModelContext(memory.container).fetch(FetchDescriptor<Conversation>()).first)
            .orderedUtterances
        #expect(rows.map(\.role) == [.user, .agent, .agent])
        #expect(rows.last?.text.hasPrefix("Larderly makes inventory and food-cost software") == true)

        let snapshot = await orchestrator.snapshot
        #expect(snapshot.toolCalls.map(\.name) == ["search_memory"])
        #expect(snapshot.toolCalls.first?.outcome == .succeeded)
        #expect(snapshot.toolCalls.first?.output == output.output)
        await orchestrator.shutdown()
    }

    // MARK: - Remember, then search

    @Test func rememberedFactsAreFoundAndForgottenOnesAreNot() async throws {
        let memory = try await Memory()
        let tools = try RealtimeToolRegistry(MemoryTools.all(backend: memory.service))
        let remember = try #require(tools.tool(named: "remember"))
        let search = try #require(tools.tool(named: "search_memory"))
        let forget = try #require(tools.tool(named: "forget"))

        let saved = try await remember.call(Data(#"{"text":"The user's sister Maya lives in Lisbon"}"#.utf8))
        let fact = try #require(
            (try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: [String: Any]])?["remembered"])
        let id = try #require(fact["id"] as? String)

        let found = try await search.call(Data(#"{"query":"where does Maya live","kinds":["fact"]}"#.utf8))
        #expect(found.contains(id))
        #expect(found.contains("The user's sister Maya lives in Lisbon"))

        // Forget: asked in one chain, confirmed in the next.
        let ask = try await RealtimeToolCallContext.$current.withValue(.init(callID: "a", chain: 1)) {
            try await forget.call(Data(#"{"id":"\#(id)"}"#.utf8))
        }
        #expect(ask.contains("needs_confirmation"))
        let confirm = try await RealtimeToolCallContext.$current.withValue(.init(callID: "b", chain: 2)) {
            try await forget.call(Data(#"{"id":"\#(id)","confirm":true}"#.utf8))
        }
        #expect(confirm.contains("\"status\":\"forgotten\""))
        let after = try await search.call(Data(#"{"query":"where does Maya live","kinds":["fact"]}"#.utf8))
        #expect(!after.contains(id))
    }

    // MARK: - Latency

    /// Acceptance criterion (client side): a tool round trip adds < 300 ms
    /// p50. Measured from the moment `response.function_call_arguments.done`
    /// and `response.done` reach the runner to the follow-up
    /// `response.create`: argument parsing, the store lookups, hybrid search
    /// over the index, labelling, the JSON output and both sends. The
    /// server's own time to answer (and the query embedding on the Neural
    /// Engine, ~10–20 ms per text, docs/embeddings.md) is not in it.
    ///
    /// Every `swift test` runs a 400-note knowledge base (≈1,200 chunks);
    /// `BLAU_INDEX_BENCHMARK=1` runs 10,000 notes (≈30,000 chunks) and
    /// prints the numbers for docs/memory-tools.md.
    @Test func aToolRoundTripAddsWellUnder300Milliseconds() async throws {
        let large = ProcessInfo.processInfo.environment["BLAU_INDEX_BENCHMARK"] == "1"
        let notes = large ? 10_000 : 400
        let memory = try await Memory(notes: notes)
        let sender = TimingSender()
        let runner = RealtimeToolRunner(
            registry: try RealtimeToolRegistry(MemoryTools.all(backend: memory.service)), sender: sender,
            signposter: .disabled(.realtime))
        let queries = [
            #"{"query":"what my company does","kinds":["company"]}"#,
            #"{"query":"food cost percent last week"}"#,
            #"{"query":"saffron menus suppliers"}"#,
            #"{"query":"pricing per location"}"#,
            #"{"query":"call the glacier team","kinds":["note"],"limit":5}"#,
        ]
        var samples: [Duration] = []
        let rounds = large ? 100 : 40
        for round in 0..<rounds {
            let response = "resp_\(round)"
            let call = "call_\(round)"
            await runner.handle(
                .responseCreated(.init(response: RealtimeResponse(id: response, status: .inProgress, output: []))))
            let start = ContinuousClock.now
            sender.expectFollowUp()
            await runner.handle(
                .responseFunctionCallArgumentsDone(
                    .init(
                        responseID: response, callID: call, name: "search_memory",
                        arguments: queries[round % queries.count])))
            await runner.handle(.responseDone(.init(response: RealtimeResponse(id: response, status: .completed))))
            let end = try await sender.followUp()
            samples.append(end - start)
            // The follow-up's own response, so the next round is a new turn.
            await runner.handle(
                .responseCreated(
                    .init(response: RealtimeResponse(id: "\(response)_f", status: .inProgress, output: []))))
            await runner.handle(
                .responseDone(.init(response: RealtimeResponse(id: "\(response)_f", status: .completed))))
        }
        #expect(sender.outputs.allSatisfy { !$0.contains("\"error\"") })
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let chunks = try await memory.index.statistics().chunks
        print(
            """
            Memory tool round trip, \(notes) notes (\(chunks) chunks), \(rounds) calls: \
            p50 \(p50.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))), \
            p95 \(p95.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))
            """)
        #expect(p50 < .milliseconds(300))
    }
}

/// Answers the runner's sends, timing the follow-up `response.create`.
final class TimingSender: RealtimeEventSending {
    private struct State {
        var outputs: [String] = []
        var waiter: CheckedContinuation<ContinuousClock.Instant, any Error>?
        var arrived: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    var outputs: [String] { state.withLock { $0.outputs } }

    func expectFollowUp() {
        state.withLock { $0.arrived = nil }
    }

    func followUp() async throws -> ContinuousClock.Instant {
        try await withCheckedThrowingContinuation { continuation in
            let arrived = state.withLock { state -> ContinuousClock.Instant? in
                if let arrived = state.arrived { return arrived }
                state.waiter = continuation
                return nil
            }
            if let arrived { continuation.resume(returning: arrived) }
        }
    }

    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        let now = ContinuousClock.now
        switch event {
        case .conversationItemCreate(.functionCallOutput(let output), _):
            state.withLock { $0.outputs.append(output.output) }
        case .responseCreate:
            let waiter = state.withLock { state -> CheckedContinuation<ContinuousClock.Instant, any Error>? in
                state.arrived = now
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: now)
        default:
            break
        }
    }
}
