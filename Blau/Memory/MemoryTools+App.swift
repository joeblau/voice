import BlauCore
import BlauMemory
import BlauRealtime
import BlauTelemetry
import os

/// Wires Grok's memory tools (#68) for the app: BlauMemory's
/// `MemoryToolService` over the indexing controller's current store and
/// index, behind BlauRealtime's tools. The two modules are siblings, so the
/// composition root is where they meet (docs/architecture.md, rule 2).
extension MemoryTools {
    /// The memory backend: reads the store and index the indexing
    /// controller has open for the current iCloud account, and embeds
    /// queries with the shared embedding service (BM25 alone until its
    /// model is installed).
    @MainActor
    static func service(
        indexing: MemoryIndexingController, textEmbeddings: TextEmbeddingService
    ) -> MemoryToolService {
        MemoryToolService(
            context: { [weak indexing] in await indexing?.toolContext },
            embedder: textEmbeddings, chunkEmbedder: textEmbeddings)
    }

    /// The tools the realtime session declares: the four memory tools when
    /// the `memoryTools` flag is on (read at launch), none otherwise.
    static func registry(backend: any MemoryToolBackend, enabled: Bool) -> RealtimeToolRegistry {
        guard enabled else { return RealtimeToolRegistry() }
        do {
            return try RealtimeToolRegistry(all(backend: backend))
        } catch {
            // Names are fixed and valid; a failure here is a programming error.
            Log.realtime.fault("Couldn't register the memory tools: \(String(describing: error), privacy: .public)")
            return RealtimeToolRegistry()
        }
    }
}
