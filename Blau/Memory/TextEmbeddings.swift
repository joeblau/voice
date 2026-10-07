import BlauMemory
import BlauTopics
import BlauTranscription
import Foundation

/// Builds the app's one shared text embedding service (#60): memory search
/// (#62 - #68) and topic segmentation (#52) both use it, so each exchange is
/// embedded once.
enum TextEmbeddings {
    /// The live service: the model `ModelManager` installs as
    /// `ModelID.textEmbedding`, loaded with Core ML on first use. Until the
    /// converted model is hosted and pinned (docs/models.md) the manager has
    /// no such model, so the service reports `notInstalled` and topics run
    /// on their fallback embedder.
    @MainActor
    static func make(models: ModelManager) -> TextEmbeddingService {
        TextEmbeddingService { [weak models] in
            await models?.textEmbeddingInstallation
        }
    }

    /// Previews and tests: never installed, never loads a model.
    static func unavailable() -> TextEmbeddingService {
        TextEmbeddingService(installation: { nil })
    }
}

extension ModelManager {
    /// Where the text embedding model is installed, with its pinned
    /// revision (recorded in every vector's `modelVersion`), or `nil`.
    var textEmbeddingInstallation: TextEmbeddingService.Installation? {
        guard let directory = directory(for: .textEmbedding) else { return nil }
        return TextEmbeddingService.Installation(directory: directory, revision: manifest[.textEmbedding]?.revision)
    }
}

extension AppEnvironment {
    /// The embedder and config for a new conversation's topic segmenter:
    /// the shared embedding service when its model is installed and loads,
    /// Apple's contextual embedding or the lexical one otherwise. The topic
    /// lifecycle (#54) calls this once per conversation:
    ///
    /// ```swift
    /// let segmenter = StreamingTopicSegmenter(embedding: await environment.topicEmbedding())
    /// ```
    func topicEmbedding() async -> TopicEmbedding {
        let textEmbeddings = textEmbeddings
        return await TopicEmbedding.best { try? await textEmbeddings.textEmbedder(for: .document) }
    }
}
