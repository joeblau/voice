import BlauCore

/// BlauMemory: Text embeddings, the local FTS5 + vector index, hybrid retrieval, fact
/// extraction and the memory tools exposed to Grok.
///
/// See docs/architecture.md for the modules it may depend on.
public enum BlauMemoryModule: BlauModule {
    public static let summary =
        "Text embeddings, the local search index, hybrid retrieval, fact extraction and memory tools"
}
