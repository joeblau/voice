import BlauCore
import BlauTelemetry
import FluidAudio
import Foundation
import os

/// Speaker embeddings from WeSpeaker ResNet34-LM on Core ML: 256-d,
/// L2-normalized, computed on the Neural Engine.
///
/// ```swift
/// let embedder = try await WeSpeakerEmbedder.load(modelDirectory: speakerModelDirectory)
/// // The gate's first score, on the first 1.5 s of a speech segment:
/// let embedding = try await embedder.embed(SpeakerEmbeddingWindow.short.prefix(of: segment))
/// let score = embedding.cosineSimilarity(to: voiceprint)
/// ```
///
/// What it does around the network:
/// - Checks each segment: 16 kHz, finite samples, at least
///   ``minimumDuration``.
/// - Runs the model once per segment (the model's three slots are three
///   masks over one waveform, so different segments can't share a run).
/// - Splits segments longer than the network's 10 s input into equal
///   pieces, embeds each and averages their directions.
/// - Normalizes every vector to unit length.
/// - Marks each call with the `voiceid.embed` signpost.
public struct WeSpeakerEmbedder: SpeakerEmbedder {
    public let model: SpeakerEmbeddingModelInfo
    public let minimumDuration: Duration

    private let network: any SpeakerEmbeddingNetwork
    private let signposter: Signposter

    /// The default ``minimumDuration``. Below half a second the embedding
    /// says little about the speaker (18% EER at 1 s already).
    public static let defaultMinimumDuration: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - network: Runs the model.
    ///   - model: Identifies the vectors `network` produces.
    ///   - minimumDuration: Shorter segments are rejected.
    ///   - signposter: Where `voiceid.embed` intervals go.
    /// - Precondition: `network.shape.dimension == model.dimension`.
    public init(
        network: any SpeakerEmbeddingNetwork,
        model: SpeakerEmbeddingModelInfo = .weSpeakerResNet34LM,
        minimumDuration: Duration = WeSpeakerEmbedder.defaultMinimumDuration,
        signposter: Signposter = Signposts.voiceID
    ) {
        precondition(
            network.shape.dimension == model.dimension,
            "The network produces \(network.shape.dimension)-d vectors, not \(model.dimension)-d")
        precondition(minimumDuration > .zero, "The minimum duration must be positive")
        self.network = network
        self.model = model
        self.minimumDuration = minimumDuration
        self.signposter = signposter
    }

    /// The bundle name of the WeSpeaker model inside the downloaded speaker
    /// model's directory (FluidAudio's `ModelNames.Diarizer.embeddingFile`).
    public static let modelBundleName = ModelNames.Diarizer.embeddingFile

    /// Loads the WeSpeaker model installed in `modelDirectory`.
    ///
    /// - Parameters:
    ///   - modelDirectory: The `.speakerEmbedding` model's directory from
    ///     `ModelManager.directory(for:)`; the bundle inside it is
    ///     ``modelBundleName``.
    ///   - computeUnits: Where Core ML runs the model. The default (Neural
    ///     Engine with CPU fallback) matches the warm-up, so it reuses the
    ///     compiled model Core ML cached then.
    public static func load(
        modelDirectory: URL,
        computeUnits: SpeakerEmbeddingComputeUnits = .cpuAndNeuralEngine
    ) async throws -> WeSpeakerEmbedder {
        let network = try await CoreMLSpeakerEmbeddingNetwork.load(
            contentsOf: modelDirectory.appending(path: modelBundleName),
            computeUnits: computeUnits
        )
        return WeSpeakerEmbedder(network: network)
    }

    public func embed(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding] {
        guard !segments.isEmpty else { return [] }
        return try await signposter.withInterval(.voiceIDEmbed) {
            do {
                return try await embedUnmeasured(segments)
            } catch let error as CancellationError {
                throw error
            } catch {
                let reason = String(describing: error)
                Log.voiceID.error(
                    "Embedding \(segments.count, privacy: .public) segment(s) failed: \(reason, privacy: .public)")
                throw error
            }
        }
    }

    private func embedUnmeasured(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding] {
        for segment in segments {
            try validate(segment)
        }
        let shape = network.shape
        var results: [SpeakerEmbedding] = []
        results.reserveCapacity(segments.count)
        for segment in segments {
            var pieces: [SpeakerEmbedding] = []
            for samples in Self.split(segment.samples, maximumLength: shape.sampleCount) {
                try Task.checkCancellation()
                let raw = try await network.embed(samples)
                guard raw.count == shape.dimension,
                    let embedding = SpeakerEmbedding(
                        normalizing: raw,
                        modelIdentifier: model.identifier,
                        audioDuration: .samples(Int64(samples.count), sampleRate: AudioFrame.captureSampleRate)
                    )
                else { throw SpeakerEmbedderError.invalidOutput }
                pieces.append(embedding)
            }
            if pieces.count == 1 {
                results.append(pieces[0])
            } else {
                guard let mean = SpeakerEmbedding.mean(of: pieces) else { throw SpeakerEmbedderError.invalidOutput }
                results.append(mean)
            }
        }
        return results
    }

    private func validate(_ segment: AudioFrame) throws(SpeakerEmbedderError) {
        guard segment.sampleRate == AudioFrame.captureSampleRate else {
            throw .unsupportedSampleRate(segment.sampleRate)
        }
        guard segment.duration >= minimumDuration else {
            throw .segmentTooShort(segment.duration, minimum: minimumDuration)
        }
        guard segment.samples.allSatisfy(\.isFinite) else {
            throw .nonFiniteSamples
        }
    }

    /// `samples` cut into the fewest pieces of at most `maximumLength`, all
    /// the same length (give or take one sample), so no piece is a short
    /// leftover with a poor embedding.
    static func split(_ samples: [Float], maximumLength: Int) -> [[Float]] {
        precondition(maximumLength > 0)
        guard samples.count > maximumLength else { return [samples] }
        let pieceCount = (samples.count + maximumLength - 1) / maximumLength
        let (base, remainder) = samples.count.quotientAndRemainder(dividingBy: pieceCount)
        var pieces: [[Float]] = []
        pieces.reserveCapacity(pieceCount)
        var start = 0
        for index in 0..<pieceCount {
            let length = base + (index < remainder ? 1 : 0)
            pieces.append(Array(samples[start..<(start + length)]))
            start += length
        }
        return pieces
    }
}
