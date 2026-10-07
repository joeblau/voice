import BlauCore
import BlauTelemetry
import CoreML
import Foundation
import os

/// The app's one text-embedding service, shared by memory (#62 - #68) and
/// topic segmentation (#52): loads the installed model once, on first use,
/// and hands the same `TextEmbeddingModel` to every caller.
///
/// The composition root builds it over `ModelManager`
/// (`ModelID.textEmbedding`): `installation` reports where the model is
/// installed, or `nil` while it is not. When the installation changes (a new
/// pinned revision, or a delete and re-download) the next call loads the new
/// one; vectors carry `modelVersion`, so the index notices.
///
/// ```swift
/// let embeddings = TextEmbeddingService { await models.textEmbeddingInstallation() }
/// let vectors = try await embeddings.embed(chunks, as: .document)
/// let segmenter = StreamingTopicSegmenter(embedder: try await embeddings.textEmbedder(), ...)
/// ```
public actor TextEmbeddingService {
    /// Where an installed model lives.
    public struct Installation: Hashable, Sendable {
        public var directory: URL
        /// The pinned revision of the installed files, for `modelVersion`.
        public var revision: String?

        public init(directory: URL, revision: String?) {
            self.directory = directory
            self.revision = revision
        }
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The model isn't downloaded (or not yet verified and installed).
        case notInstalled

        public var description: String {
            switch self {
            case .notInstalled: "The text embedding model is not installed"
            }
        }
    }

    /// Loads the model of an installation.
    public typealias Loader = @Sendable (Installation) async throws -> TextEmbeddingModel

    private let installation: @Sendable () async -> Installation?
    private let loader: Loader
    private var loaded: (installation: Installation, model: TextEmbeddingModel)?
    private var loading: (installation: Installation, task: Task<TextEmbeddingModel, any Error>)?
    /// The last load failure, not retried until the installation changes or
    /// `retry()` is called: a model that can't load won't load on the next
    /// sentence either, and each attempt costs seconds.
    private var failure: (installation: Installation, error: any Error)?

    /// - Parameters:
    ///   - installation: Where the model is installed now, or `nil`.
    ///   - loader: Loads an installation; Core ML on the Neural Engine by
    ///     default.
    public init(
        installation: @escaping @Sendable () async -> Installation?,
        loader: @escaping Loader = TextEmbeddingService.coreMLLoader()
    ) {
        self.installation = installation
        self.loader = loader
    }

    /// Loads a bundle with Core ML (`TextEmbeddingModel.load`).
    public static func coreMLLoader(
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        batchSize: Int = TextEmbeddingModel.defaultBatchSize
    ) -> Loader {
        { installation in
            let bundle = try TextEmbeddingBundle(directory: installation.directory)
            return try await TextEmbeddingModel.load(
                bundle: bundle, revision: installation.revision, computeUnits: computeUnits, batchSize: batchSize)
        }
    }

    /// Whether a model is installed (it may not be loaded yet).
    public var isInstalled: Bool {
        get async { await installation() != nil }
    }

    /// Whether a model is loaded and ready.
    public var isLoaded: Bool { loaded != nil }

    /// The loaded model, loading it first if needed. Concurrent callers share
    /// one load.
    ///
    /// - Throws: `Failure.notInstalled`, or why the model couldn't load.
    public func model() async throws -> TextEmbeddingModel {
        guard let current = await installation() else {
            if loaded != nil {
                Log.memory.notice("Text embedding model uninstalled; unloading it")
                loaded = nil
            }
            throw Failure.notInstalled
        }
        if let loaded, loaded.installation == current { return loaded.model }
        if let failure, failure.installation == current { throw failure.error }

        let task: Task<TextEmbeddingModel, any Error>
        if let loading, loading.installation == current {
            task = loading.task
        } else {
            let loader = loader
            task = Task { try await loader(current) }
            loading = (current, task)
        }
        do {
            let model = try await task.value
            if loading?.installation == current { loading = nil }
            loaded = (current, model)
            failure = nil
            return model
        } catch {
            if loading?.installation == current { loading = nil }
            failure = (current, error)
            Log.memory.error(
                "Couldn't load the text embedding model: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Embeds `texts` as `task` with the shared model, in batches of
    /// `TextEmbeddingModel.defaultBatchSize`.
    public func embed(_ texts: [String], as task: TextEmbeddingTask) async throws -> [TextEmbedding] {
        try await model().embed(texts, as: task)
    }

    /// The shared model as a `TextEmbedder` (the protocol the topic
    /// segmenter takes), embedding every text as `task`.
    public func textEmbedder(for task: TextEmbeddingTask = .document) async throws -> SharedTextEmbedder {
        SharedTextEmbedder(model: try await model(), task: task)
    }

    /// Forgets a load failure so the next call tries again.
    public func retry() {
        failure = nil
    }

    /// Drops the loaded model (its memory is freed once no caller holds it).
    /// The next call loads it again.
    public func unload() {
        loaded = nil
    }
}

/// The shared text-embedding model as a BlauCore `TextEmbedder`, so the topic
/// segmenter (BlauTopics, which can't import BlauMemory) can use it through
/// the composition root.
///
/// Returns the stored representation dequantized: the 256-d Matryoshka
/// prefix, unit length, after int8 quantization, so the segmenter compares
/// exactly the vectors the memory index stores for the same exchange.
public struct SharedTextEmbedder: TextEmbedder {
    public let model: TextEmbeddingModel
    public let task: TextEmbeddingTask

    public init(model: TextEmbeddingModel, task: TextEmbeddingTask = .document) {
        self.model = model
        self.task = task
    }

    /// The model's `modelVersion`.
    public var modelIdentifier: String { model.modelVersion }

    public func embed(_ text: String) async throws -> [Float] {
        guard text.contains(where: { !$0.isWhitespace }) else {
            return [Float](repeating: 0, count: model.storedDimensions)
        }
        return try await model.embed(text, as: task).vector
    }
}
