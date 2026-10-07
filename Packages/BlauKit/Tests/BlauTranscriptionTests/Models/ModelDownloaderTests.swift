import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

@Suite("Model downloader")
struct ModelDownloaderTests {
    let manifest = ModelFixtures.manifest(bytesPerFile: 8192)

    private func downloader(
        _ transport: some ModelTransport, clock: any BlauClock = ManualClock(), policy: ModelRetryPolicy = .immediate
    ) -> ModelDownloader {
        ModelDownloader(transport: transport, clock: clock, retryPolicy: policy, host: ModelDescriptor.defaultHost)
    }

    private func weights(of id: ModelID) -> String { "\(id.rawValue)/\(id.rawValue).mlmodelc/weights/weight.bin" }

    @Test func downloadsAndVerifiesEveryFile() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        let reported = Mutex<[Int64]>([])

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { bytes in
            reported.withLock { $0.append(bytes) }
        }

        let staging = store.stagingDirectory(for: descriptor)
        for file in descriptor.files {
            #expect(try ModelStore.sha256(of: staging.appending(path: file.path)) == file.sha256)
        }
        #expect(transport.calls.count == descriptor.files.count)
        #expect(transport.calls.allSatisfy { $0.offset == 0 && !$0.allowsExpensiveNetwork })
        let progress = reported.withLock { $0 }
        #expect(progress.first == 0)
        #expect(progress.last == descriptor.totalBytes)
        #expect(progress == progress.sorted(), "Progress must never go backwards")
    }

    /// Resume: a dropped connection continues from the bytes on disk.
    @Test func resumesADroppedTransferFromTheBytesOnDisk() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.parakeetRealtimeEOU])
        let transport = ScriptedTransport(manifest: manifest)
        let path = weights(of: .parakeetRealtimeEOU)
        transport.script(path, .drop(afterBytes: 3000), .drop(afterBytes: 2000), .serve)

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        #expect(transport.calls.filter { $0.path == path }.map(\.offset) == [0, 3000, 5000])
        let staged = store.stagingDirectory(for: descriptor).appending(
            path: "parakeetRealtimeEOU.mlmodelc/weights/weight.bin")
        let file = try #require(descriptor.files.first { $0.path.hasSuffix("weights/weight.bin") })
        #expect(try ModelStore.sha256(of: staged) == file.sha256)
    }

    /// Resume across launches: a `.partial` left by a killed app is picked up.
    @Test func resumesAPartialFileFromAPreviousLaunch() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let file = try #require(descriptor.files.first { $0.path.hasSuffix("weight.bin") })
        let partial = ModelDownloader.partialURL(for: file, in: store.stagingDirectory(for: descriptor))
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ModelFixtures.contents(of: file, in: descriptor).prefix(1234).write(to: partial)
        let transport = ScriptedTransport(manifest: manifest)

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        #expect(transport.calls.first { $0.path == weights(of: .sileroVAD) }?.offset == 1234)
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
    }

    @Test func skipsFilesAlreadyVerifiedInStaging() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        transport.script(weights(of: .sileroVAD), .fail(.httpStatus(404)))
        await #expect(throws: ModelDownloadError.server(status: 404, path: "sileroVAD.mlmodelc/weights/weight.bin")) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        let firstRun = transport.calls.count

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        // The file that already succeeded isn't fetched again.
        #expect(
            transport.calls.dropFirst(firstRun).map(\.path) == [weights(of: .sileroVAD), "sileroVAD/vocab.json"])
    }

    @Test func aServerThatIgnoresRangeRestartsTheFile() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        transport.script(weights(of: .sileroVAD), .drop(afterBytes: 100), .ignoreRange)

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        let staged = store.stagingDirectory(for: descriptor).appending(path: "sileroVAD.mlmodelc/weights/weight.bin")
        #expect(ModelStore.size(of: staged) == 8192)
    }

    /// Checksums: a corrupt file is discarded and fetched again from scratch.
    @Test func refetchesAFileThatFailsItsChecksum() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.speakerEmbedding])
        let transport = ScriptedTransport(manifest: manifest)
        let path = weights(of: .speakerEmbedding)
        transport.script(path, .corrupt, .serve)

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        #expect(transport.calls.filter { $0.path == path }.map(\.offset) == [0, 0])
    }

    @Test func givesUpOnAFileThatKeepsFailingItsChecksum() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.speakerEmbedding])
        let transport = ScriptedTransport(manifest: manifest)
        transport.script(weights(of: .speakerEmbedding), .corrupt, .corrupt, .serve)

        await #expect(throws: ModelDownloadError.checksumMismatch(path: "speakerEmbedding.mlmodelc/weights/weight.bin"))
        {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        let partial = ModelDownloader.partialURL(
            for: try #require(descriptor.files.first { $0.path.hasSuffix("weight.bin") }),
            in: store.stagingDirectory(for: descriptor))
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
    }

    /// Retry: transient errors back off exponentially on the injected clock.
    @Test func retriesTransientFailuresWithBackoff() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        let path = weights(of: .sileroVAD)
        transport.script(path, .fail(.httpStatus(503)), .fail(.interrupted("timeout")), .serve)
        let clock = ManualClock()
        let policy = ModelRetryPolicy(maxAttempts: 5, initialDelay: .seconds(1), maxDelay: .seconds(30))
        let loader = downloader(transport, clock: clock, policy: policy)

        let task = Task {
            try await loader.download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        await clock.waitForSleepers()
        #expect(transport.calls.filter { $0.path == path }.count == 1)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers()
        #expect(transport.calls.filter { $0.path == path }.count == 2)
        // Second retry waits twice as long.
        clock.advance(by: .seconds(1))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await task.value

        #expect(transport.calls.filter { $0.path == path }.count == 3)
    }

    @Test func givesUpAfterTheRetryBudget() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        transport.setDefault(.fail(.interrupted("reset")))

        await #expect(throws: ModelDownloadError.self) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        #expect(transport.calls.count == ModelRetryPolicy.immediate.maxAttempts)
    }

    /// An attempt that made progress doesn't use up the budget.
    @Test func progressResetsTheRetryBudget() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        let path = weights(of: .sileroVAD)
        let drops = (0..<6).map { _ in TransportStep.drop(afterBytes: 1000) }
        for step in drops { transport.script(path, step) }

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }

        #expect(transport.calls.filter { $0.path == path }.count == 7)
    }

    @Test func doesNotRetryPermanentErrors() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        transport.setDefault(.fail(.httpStatus(403)))

        await #expect(throws: ModelDownloadError.server(status: 403, path: descriptor.files[0].path)) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        #expect(transport.calls.count == 1)
    }

    @Test func reportsOfflineAndExpensiveNetworksWithoutRetrying() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)

        transport.setDefault(.fail(.offline))
        await #expect(throws: ModelDownloadError.offline) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        transport.setDefault(.fail(.expensiveNetworkDisallowed))
        await #expect(throws: ModelDownloadError.requiresUnmeteredNetwork) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        #expect(transport.calls.count == 2)
    }

    @Test func passesTheNetworkPolicyToTheTransport() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)

        try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: true) { _ in }

        #expect(transport.calls.allSatisfy { $0.allowsExpensiveNetwork })
    }

    @Test func refusesToStartWithoutEnoughFreeSpace() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url, availableCapacity: { _ in 10_000 })
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)

        await #expect(
            throws: ModelDownloadError.insufficientStorage(required: descriptor.totalBytes, available: 10_000)
        ) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        #expect(transport.calls.isEmpty)
    }

    @Test func diskWriteFailuresAreStorageErrors() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        transport.setDefault(.fail(.writeFailed("disk full")))

        await #expect(throws: ModelDownloadError.storage("disk full")) {
            try await downloader(transport).download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
    }

    @Test func cancellationStopsTheDownloadAndKeepsPartialBytes() async throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let transport = ScriptedTransport(manifest: manifest)
        let gate = Gate()
        transport.script(weights(of: .sileroVAD), .pause(afterBytes: 4000, gate: gate))
        let loader = downloader(transport)

        let task = Task {
            try await loader.download(descriptor, store: store, allowsExpensiveNetwork: false) { _ in }
        }
        while !transport.calls.contains(where: { $0.path == weights(of: .sileroVAD) }) { await Task.yield() }
        task.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }

        let file = try #require(descriptor.files.first { $0.path.hasSuffix("weight.bin") })
        let partial = ModelDownloader.partialURL(for: file, in: store.stagingDirectory(for: descriptor))
        #expect(ModelStore.size(of: partial) == 4000)
    }

    @Test func backoffDoublesAndCaps() {
        let policy = ModelRetryPolicy(maxAttempts: 10, initialDelay: .seconds(1), maxDelay: .seconds(30))
        #expect((1...7).map { policy.delay(afterAttempt: $0) } == [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) })
        #expect(ModelRetryPolicy.default.maxAttempts == 5)
    }
}
