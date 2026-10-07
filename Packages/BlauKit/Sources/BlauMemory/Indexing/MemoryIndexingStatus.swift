import Foundation

/// How far a long job (a rebuild, or embedding a backlog) has got.
public struct MemoryIndexingProgress: Hashable, Sendable {
    /// Sources (rebuild) or chunks (embedding) done.
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// 0...1; 1 for an empty job.
    public var fractionCompleted: Double {
        total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 1
    }
}

/// What the incremental indexer (#63) is doing, for Settings and the BG
/// task scheduler.
public struct MemoryIndexingStatus: Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        /// Not started, or reading its saved state.
        case starting
        /// Up to date with the store.
        case idle
        /// Applying store changes (this device's or another's).
        case indexingChanges
        /// Re-reading every source, newest first (`rebuild`).
        case rebuilding
        /// Embedding chunks that have no vector of the current model
        /// (`embedding`).
        case embedding
        /// Held back by the thermal and power policy (#75).
        case waiting(IndexingMode)
    }

    public var activity: Activity
    /// A rebuild waiting or in progress, in sources. It survives a
    /// relaunch.
    public var rebuild: MemoryIndexingProgress?
    /// Chunks waiting for a vector of the current model, in chunks.
    public var embedding: MemoryIndexingProgress?
    /// Chunks in the index.
    public var chunkCount: Int
    /// Of those, chunks with a vector of the current model.
    public var vectorCount: Int
    /// When the last full rebuild finished.
    public var lastRebuild: Date?
    /// When the last store change was applied.
    public var lastIndexed: Date?
    /// Why chunks are indexed for keyword search only (no embedding model,
    /// or it failed), or `nil`.
    public var vectorsUnavailable: String?
    /// The last error, cleared by the next successful pass.
    public var lastError: String?

    public init(
        activity: Activity = .starting,
        rebuild: MemoryIndexingProgress? = nil,
        embedding: MemoryIndexingProgress? = nil,
        chunkCount: Int = 0,
        vectorCount: Int = 0,
        lastRebuild: Date? = nil,
        lastIndexed: Date? = nil,
        vectorsUnavailable: String? = nil,
        lastError: String? = nil
    ) {
        self.activity = activity
        self.rebuild = rebuild
        self.embedding = embedding
        self.chunkCount = chunkCount
        self.vectorCount = vectorCount
        self.lastRebuild = lastRebuild
        self.lastIndexed = lastIndexed
        self.vectorsUnavailable = vectorsUnavailable
        self.lastError = lastError
    }

    /// A rebuild or an embedding backlog is left: what the background
    /// processing task is scheduled for.
    public var hasPendingWork: Bool { rebuild != nil || embedding != nil }
}
