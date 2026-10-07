import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app-side pieces of the voice loop (#36). The orchestrator itself is
/// covered by `swift test` in BlauKit.
@Suite("Voice loop")
@MainActor
struct VoiceLoopTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func utterance(_ text: String, _ speaker: Speaker, in conversation: ConversationID, at offset: Double)
        -> BlauCore.Utterance
    {
        BlauCore.Utterance(
            conversationID: conversation, speaker: speaker, text: text,
            timeRange: TimeRange(start: .seconds(offset), duration: .seconds(1)),
            startedAt: Self.t0.addingTimeInterval(offset))
    }

    /// The recorder writes both roles into the store the persistence
    /// controller has open.
    @Test func theRecorderWritesBothRolesIntoTheOpenStore() async throws {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        try await recorder.record(utterance("How are you?", .user, in: conversation, at: 0))
        try await recorder.record(utterance("Doing well.", .agent, in: conversation, at: 2))
        try await recorder.finishConversation(conversation, at: Self.t0.addingTimeInterval(5))

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
        #expect(stored.id == conversation.rawValue)
        #expect(stored.endedAt != nil)
        #expect(stored.orderedUtterances.map(\.role) == [.user, .agent])
        #expect(stored.orderedUtterances.map(\.text) == ["How are you?", "Doing well."])
    }

    /// When the container is replaced mid-conversation (an iCloud account
    /// change), the conversation is reopened in the new store.
    @Test func aReplacedContainerGetsTheConversationReopened() async throws {
        let first = try BlauModelContainer.makeInMemory()
        let second = try BlauModelContainer.makeInMemory()
        let current = CurrentContainer(first)
        let recorder = PersistenceTranscriptRecorder { current.value }
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        try await recorder.record(utterance("Before", .user, in: conversation, at: 0))
        current.value = second
        try await recorder.record(utterance("After", .agent, in: conversation, at: 2))
        try await recorder.flush()

        let before = try ModelContext(first).fetch(FetchDescriptor<StoredUtterance>())
        let after = try ModelContext(second).fetch(FetchDescriptor<StoredUtterance>())
        #expect(before.map(\.text) == ["Before"])
        #expect(after.map(\.text) == ["After"])
        #expect(after.first?.conversation?.id == conversation.rawValue)
    }

    /// The transcript and the topic lifecycle (#54) can both ask for the
    /// store right after the container is replaced; they get the same one,
    /// with the conversation reopened, so neither write is dropped.
    @Test func callersAfterAContainerSwapShareOneStore() async throws {
        let first = try BlauModelContainer.makeInMemory()
        let second = try BlauModelContainer.makeInMemory()
        let current = CurrentContainer(first)
        let recorder = PersistenceTranscriptRecorder { current.value }
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        current.value = second
        async let one = recorder.conversationStore()
        async let two = recorder.conversationStore()
        let (storeOne, storeTwo) = try await (one, two)
        #expect(storeOne === storeTwo)
        #expect(storeOne.modelContainer === second)

        try await recorder.record(utterance("After", .agent, in: conversation, at: 2))
        try await recorder.flush()
        let after = try ModelContext(second).fetch(FetchDescriptor<StoredUtterance>())
        #expect(after.map(\.text) == ["After"])
        #expect(after.first?.conversation?.id == conversation.rawValue)
    }

    @Test func noOpenStoreIsAnError() async {
        let recorder = PersistenceTranscriptRecorder { nil }
        await #expect(throws: PersistenceTranscriptRecorder.StoreUnavailableError.self) {
            try await recorder.beginConversation(ConversationID(), at: Self.t0)
        }
    }

    @Test func theHUDRowsFollowTheSnapshot() {
        let loop = VoiceLoop(
            realtime: FakeRealtimeService(), speechModels: SpeechModels.fixtureManager(),
            performance: FixedPerformanceLevel())
        #expect(!loop.isAvailable)
        #expect(loop.hudReadout.value(for: "EOU → audio") == "–")
        #expect(
            loop.hudReadout.rows.map(\.label) == [
                "Turn", "Realtime", "Session", "EOU → audio", "Turn time", "Tokens", "Barge-in",
            ])
    }

    // MARK: Start and stop (#41)

    private func makeLoop(
        _ conversation: FakeLoopConversation, released: Counter = Counter(),
        _ startPipeline: @escaping VoiceLoop.PipelineStarter
    ) -> VoiceLoop {
        VoiceLoop(
            conversation: conversation, snapshots: nil, startPipeline: startPipeline,
            releaseAudio: { released.count += 1 }, performance: FixedPerformanceLevel())
    }

    @Test func startRunsAndStopEndsEverything() async {
        let conversation = FakeLoopConversation()
        let pipeline = FakeLoopPipeline()
        let released = Counter()
        let loop = makeLoop(conversation, released: released) { pipeline }
        #expect(loop.isAvailable)

        await loop.start()
        #expect(loop.phase == .running)
        #expect(conversation.opens == 1)
        #expect(conversation.isOpen)

        await loop.stop()
        #expect(loop.phase == .idle)
        #expect(!conversation.isOpen)
        #expect(pipeline.stops == 1)
        #expect(released.count == 0, "the pipeline released the microphone")
    }

    /// The Live Activity's Stop while the models load (the pipeline is
    /// still starting): the start unwinds instead of opening the realtime
    /// session, and releases the pipeline it went on to build.
    @Test func aStopWhileThePipelineStartsEndsTheStart() async throws {
        let conversation = FakeLoopConversation()
        let pipeline = FakeLoopPipeline()
        let gate = StartGate()
        let released = Counter()
        let loop = makeLoop(conversation, released: released) {
            await gate.wait()
            return pipeline
        }

        let start = Task { await loop.start() }
        try await until("the pipeline is starting") { gate.isWaiting }
        #expect(loop.phase == .starting)

        await loop.stop()
        #expect(loop.phase == .idle)
        #expect(released.count == 1, "the microphone coming up is turned off at once")

        gate.open()
        await start.value
        #expect(loop.phase == .idle)
        #expect(conversation.opens == 0, "Grok was never connected")
        #expect(pipeline.stops == 1, "the late pipeline was released")
        #expect(loop.startError == nil)
    }

    /// A pipeline start that notices the stop itself (the keeper went
    /// `.inactive`) throws `CancellationError`; that isn't a failed start.
    @Test func aCancelledPipelineStartIsNotAFailure() async throws {
        let conversation = FakeLoopConversation()
        let gate = StartGate()
        let loop = makeLoop(conversation) {
            await gate.wait()
            throw CancellationError()
        }

        let start = Task { await loop.start() }
        try await until("the pipeline is starting") { gate.isWaiting }
        await loop.stop()
        gate.open()
        await start.value

        #expect(loop.phase == .idle)
        #expect(loop.startError == nil)
        #expect(conversation.opens == 0)
    }

    /// The Stop while the realtime session opens: the conversation is
    /// closed once it has opened, and nothing keeps running.
    @Test func aStopWhileTheConversationOpensClosesIt() async throws {
        let gate = StartGate()
        let conversation = FakeLoopConversation(openGate: gate)
        let pipeline = FakeLoopPipeline()
        let loop = makeLoop(conversation) { pipeline }

        let start = Task { await loop.start() }
        try await until("the conversation is opening") { gate.isWaiting }

        await loop.stop()
        #expect(loop.phase == .idle)
        #expect(pipeline.stops == 1)

        gate.open()
        await start.value
        #expect(loop.phase == .idle)
        #expect(conversation.opens == 1)
        #expect(!conversation.isOpen, "closed after it opened")
        #expect(pipeline.stops == 1, "stop() released the pipeline; the start didn't again")
    }

    /// A new start waits for one the Stop cut short to finish unwinding, so
    /// releasing the old pipeline can't turn off the new microphone.
    @Test func aNewStartWaitsForAnUnwindingOne() async throws {
        let conversation = FakeLoopConversation()
        let gate = StartGate()
        let first = FakeLoopPipeline()
        let second = FakeLoopPipeline()
        let builds = Counter()
        let loop = makeLoop(conversation) {
            builds.count += 1
            if builds.count == 1 {
                await gate.wait()
                return first
            }
            return second
        }

        let firstStart = Task { await loop.start() }
        try await until("the first pipeline is starting") { gate.isWaiting }
        await loop.stop()

        let secondStart = Task { await loop.start() }
        for _ in 0..<20 { await Task.yield() }
        #expect(builds.count == 1, "the second start waits")

        gate.open()
        await firstStart.value
        await secondStart.value
        #expect(builds.count == 2)
        #expect(loop.phase == .running)
        #expect(first.stops == 1)
        #expect(second.stops == 0)
        #expect(conversation.opens == 1)

        await loop.stop()
        #expect(second.stops == 1)
    }

    /// Polls `condition` until it holds, failing after 10 s.
    private func until(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
            try await Task.sleep(for: .microseconds(200))
        }
    }
}

/// Holds an `await` until the test opens it.
@MainActor
private final class StartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Counter {
    var count = 0
}

@MainActor
private final class FakeLoopConversation: VoiceLoopConversation {
    private let openGate: StartGate?
    private(set) var opens = 0
    private(set) var isOpen = false

    init(openGate: StartGate? = nil) {
        self.openGate = openGate
    }

    func open() async throws {
        await openGate?.wait()
        opens += 1
        isOpen = true
    }

    func close() async {
        isOpen = false
    }

    func run(transcript events: AsyncStream<TranscriptEvent>) async {
        for await _ in events {}
    }
}

@MainActor
private final class FakeLoopPipeline: VoiceLoopPipeline {
    let transcript: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private(set) var stops = 0

    init() {
        (transcript, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
    }

    func stopListening() async {
        continuation.finish()
    }

    func stop() async {
        stops += 1
        continuation.finish()
    }
}

/// The container a test's recorder sees; swapped to simulate an iCloud
/// account change.
@MainActor
private final class CurrentContainer {
    var value: ModelContainer?

    init(_ value: ModelContainer?) {
        self.value = value
    }
}
