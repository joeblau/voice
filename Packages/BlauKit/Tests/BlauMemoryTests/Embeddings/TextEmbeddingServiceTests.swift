import BlauCore
import BlauMemory
import Foundation
import Synchronization
import Testing

@Suite("Text embedding service")
struct TextEmbeddingServiceTests {
    typealias Support = TextEmbeddingTestSupport
    typealias Installation = TextEmbeddingService.Installation

    /// Where the fake model manager says the model is.
    final class FakeInstallations: Sendable {
        let current = Mutex<Installation?>(nil)
        let loads = Mutex<[Installation]>([])
        let failures = Mutex(0)

        func loader() -> TextEmbeddingService.Loader {
            { installation in
                self.loads.withLock { $0.append(installation) }
                if self.failures.withLock({ value in
                    defer { value = max(0, value - 1) }
                    return value > 0
                }) {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Give concurrent callers a chance to pile up on the load.
                try await Task.sleep(for: .milliseconds(20))
                return Support.model(version: "fake@\(installation.revision ?? "-")")
            }
        }

        func service() -> TextEmbeddingService {
            TextEmbeddingService(installation: { self.current.withLock { $0 } }, loader: loader())
        }
    }

    static let first = Installation(directory: URL(filePath: "/models/textEmbedding/aaa"), revision: "aaa")
    static let second = Installation(directory: URL(filePath: "/models/textEmbedding/bbb"), revision: "bbb")

    @Test func reportsAMissingModel() async throws {
        let installations = FakeInstallations()
        let service = installations.service()
        #expect(await !service.isInstalled)
        await #expect(throws: TextEmbeddingService.Failure.notInstalled) {
            try await service.embed(["x"], as: .document)
        }
        #expect(installations.loads.withLock { $0 }.isEmpty)
    }

    @Test func loadsOnceForConcurrentCallers() async throws {
        let installations = FakeInstallations()
        installations.current.withLock { $0 = Self.first }
        let service = installations.service()
        #expect(await !service.isLoaded)

        let versions = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { try await service.embed(["text \(index)"], as: .document)[0].modelVersion }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(versions) == ["fake@aaa"])
        #expect(installations.loads.withLock { $0 } == [Self.first])
        #expect(await service.isLoaded)
    }

    @Test func followsTheInstallation() async throws {
        let installations = FakeInstallations()
        installations.current.withLock { $0 = Self.first }
        let service = installations.service()
        #expect(try await service.model().modelVersion == "fake@aaa")

        // A new pinned revision is installed: the next call loads it.
        installations.current.withLock { $0 = Self.second }
        #expect(try await service.model().modelVersion == "fake@bbb")

        // Deleted: unloaded, and calls fail until it is back.
        installations.current.withLock { $0 = nil }
        await #expect(throws: TextEmbeddingService.Failure.notInstalled) { try await service.model() }
        #expect(await !service.isLoaded)
        #expect(installations.loads.withLock { $0 } == [Self.first, Self.second])
    }

    @Test func remembersALoadFailureUntilRetried() async throws {
        let installations = FakeInstallations()
        installations.current.withLock { $0 = Self.first }
        installations.failures.withLock { $0 = 1 }
        let service = installations.service()

        await #expect(throws: CocoaError.self) { try await service.model() }
        await #expect(throws: CocoaError.self) { try await service.model() }
        #expect(installations.loads.withLock { $0.count } == 1, "a failed model isn't reloaded on every call")

        await service.retry()
        #expect(try await service.model().modelVersion == "fake@aaa")
        #expect(installations.loads.withLock { $0.count } == 2)
    }

    @Test func servesTheTopicSegmenterThroughTextEmbedder() async throws {
        let installations = FakeInstallations()
        installations.current.withLock { $0 = Self.first }
        let service = installations.service()
        let embedder: any TextEmbedder = try await service.textEmbedder()
        #expect(embedder.modelIdentifier == "fake@aaa")

        let vector = try await embedder.embed("an exchange about sourdough")
        #expect(vector.count == 2)
        #expect(abs(vector[0] - 0.6) < 0.01 && abs(vector[1] - 0.8) < 0.01)
        #expect(try await embedder.embed("  \n") == [0, 0])
        #expect(try await embedder.embed("") == [0, 0])
    }
}
