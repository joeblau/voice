import BlauCore
import BlauPersistence
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

/// The acceptance criterion's second half (#63): a rebuild of 10k chunks
/// completes, and resumes where it stopped after the app is killed.
///
/// "Killed" here means everything in memory is gone: the run is cancelled
/// mid-pass, the index and indexer are released, and a new indexer opens
/// the same file. Only what is on disk carries over.
@Suite("Memory indexer: resumable rebuild", .timeLimit(.minutes(5)))
struct MemoryIndexerRebuildTests {
    typealias Support = IndexTestSupport
    typealias Fakes = IndexerTestSupport

    /// 500 conversations of 20 exchanges each: 10,000 chunks.
    static func tenThousandChunks() -> Fakes.FakeReader {
        let conversations = (0..<500).map { number in
            let start = Support.t0.addingTimeInterval(Double(number) * 3_600)
            let turns: [(UtteranceRole, String)] = (0..<20).flatMap { exchange in
                [
                    (UtteranceRole.user, "Conversation \(number) question \(exchange) about topic \(number % 37)"),
                    (UtteranceRole.agent, "Answer \(exchange) for conversation \(number), detail \(exchange * number)"),
                ]
            }
            return Support.conversation(start: start, turns)
        }
        return Fakes.FakeReader(Support.FakeSources(conversations: conversations))
    }

    @Test func aTenThousandChunkRebuildResumesAfterAKill() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MemoryIndex.fileName)
        let reader = Self.tenThousandChunks()
        let reference = try await Fakes.referenceFingerprint(reader)
        #expect(reference.count == 10_000)
        let newest = reader.contents.conversations.last!.id

        // First launch: killed after a few batches.
        let (written, firstEmbedded, checkpoint) = try await {
            let index = try MemoryIndex.open(at: url)
            let run = Mutex<Task<Void, any Error>?>(nil)
            let embedder = Fakes.ObservedEmbedder { number, _ in
                if number == 9 { run.withLock { $0?.cancel() } }
            }
            let indexer = Fakes.indexer(index: index, reader: reader, embedder: embedder)
            let task = Task { try await indexer.runUntilIdle() }
            run.withLock { $0 = task }
            await #expect(throws: CancellationError.self) { try await task.value }
            let firstReads = reader.conversationReads.first { !$0.isEmpty }
            #expect(firstReads?.contains(newest) == true)
            let status = await indexer.currentStatus
            #expect(status.rebuild != nil)
            return (
                try await index.statistics(modelVersion: embedder.base.version).vectors,
                embedder.embeddedTexts.count,
                try await index.stateValue(forKey: MemoryIndexer.fullPassKey)
            )
        }()
        #expect(checkpoint != nil)
        #expect(written > 0 && written < 10_000)
        #expect(try await MemoryIndex.open(at: url).needsRebuild)

        // Relaunch: a new index on the same file, a new indexer.
        let index = try MemoryIndex.open(at: url)
        let feed = Fakes.ScriptedFeed()
        let embedder = Fakes.ObservedEmbedder()
        let resumed = Fakes.FakeReader(reader.sources)
        let indexer = Fakes.indexer(index: index, reader: resumed, feed: feed, embedder: embedder)
        let started = ContinuousClock.now
        try await indexer.runUntilIdle()
        let elapsed = ContinuousClock.now - started

        // It picked up after the checkpoint instead of starting over...
        #expect(feed.skips == 0)
        #expect(resumed.conversationReads.first { !$0.isEmpty }?.contains(newest) == false)
        // ...embedding only what the first run hadn't stored.
        #expect(embedder.embeddedTexts.count == 10_000 - written)
        #expect(firstEmbedded >= written)
        // And the result is exactly a from-scratch rebuild.
        #expect(try await index.needsRebuild == false)
        #expect(try await Fakes.fingerprint(index) == reference)
        #expect(try await index.stateValue(forKey: MemoryIndexer.fullPassKey) == nil)
        let status = await indexer.currentStatus
        #expect(status.chunkCount == 10_000)
        #expect(status.vectorCount == 10_000)
        #expect(status.rebuild == nil)
        print("Resumed 10k-chunk rebuild: \(10_000 - written) chunks in \(elapsed)")
    }

    @Test func progressCountsSourcesAndSurvivesTheRelaunch() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MemoryIndex.fileName)
        let reader = Fakes.FakeReader(
            Support.FakeSources(conversations: Array(Self.tenThousandChunks().contents.conversations.prefix(40))))

        let firstProgress = try await {
            let index = try MemoryIndex.open(at: url)
            let run = Mutex<Task<Void, any Error>?>(nil)
            let embedder = Fakes.ObservedEmbedder { number, _ in
                if number == 3 { run.withLock { $0?.cancel() } }
            }
            let indexer = Fakes.indexer(
                index: index, reader: reader, embedder: embedder,
                configuration: MemoryIndexer.Configuration(
                    debounce: .zero, conversationsPerStep: 4, writeBatchSize: 1_000, retryDelay: .zero))
            let task = Task { try await indexer.runUntilIdle() }
            run.withLock { $0 = task }
            _ = try? await task.value
            return await indexer.currentStatus.rebuild
        }()
        let progress = try #require(firstProgress)
        #expect(progress.total == 40)
        #expect(progress.completed == 8)

        let index = try MemoryIndex.open(at: url)
        let indexer = Fakes.indexer(index: index, reader: reader)
        let updates = await indexer.statusUpdates()
        let seen = Mutex<[MemoryIndexingProgress]>([])
        let watcher = Task {
            for await status in updates {
                if let rebuild = status.rebuild { seen.withLock { $0.append(rebuild) } }
            }
        }
        try await indexer.runUntilIdle()
        watcher.cancel()

        let reported = seen.withLock { $0 }
        #expect(reported.first == MemoryIndexingProgress(completed: 8, total: 40))
        #expect(reported.map(\.completed) == reported.map(\.completed).sorted())
        #expect(reported.allSatisfy { $0.total == 40 })
        #expect(reported.last?.completed == 40)
    }
}
