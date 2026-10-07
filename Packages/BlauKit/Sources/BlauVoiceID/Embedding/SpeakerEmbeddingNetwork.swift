/// The fixed tensor layout of FluidAudio's WeSpeaker Core ML conversion.
///
/// The model comes from pyannote's diarization pipeline, where one 10 s
/// chunk holds up to three local speakers: it takes a `waveform`
/// [`slotCount`, `sampleCount`] and a per-frame speaker `mask`
/// [`slotCount`, `maskFrameCount`], and returns `embedding`
/// [`slotCount`, `dimension`], one vector per mask. **Only the first
/// waveform row is read**; the three outputs are three masks pooled over
/// that one waveform (the converted program slices `waveform[0:1]`). The
/// filterbank front end, its mean normalization over the whole 10 s, and the
/// mask-weighted statistics pooling are all inside the model.
public struct SpeakerEmbeddingNetworkShape: Hashable, Sendable {
    /// Rows of the waveform, mask and embedding tensors.
    public let slotCount: Int
    /// Samples in the waveform (10 s at 16 kHz).
    public let sampleCount: Int
    /// Mask frames over the waveform.
    public let maskFrameCount: Int
    /// Values per embedding.
    public let dimension: Int

    public init(slotCount: Int, sampleCount: Int, maskFrameCount: Int, dimension: Int) {
        precondition(slotCount > 0 && sampleCount > 0 && maskFrameCount > 0 && dimension > 0)
        self.slotCount = slotCount
        self.sampleCount = sampleCount
        self.maskFrameCount = maskFrameCount
        self.dimension = dimension
    }

    /// `wespeaker_v2.mlmodelc`: `waveform` [3, 160000], `mask` [3, 589] in,
    /// `embedding` [3, 256] out.
    public static let weSpeaker = SpeakerEmbeddingNetworkShape(
        slotCount: 3,
        sampleCount: 160_000,
        maskFrameCount: 589,
        dimension: 256
    )

    /// Checks a model's tensor shapes and returns the layout they describe.
    ///
    /// - Parameters:
    ///   - waveform: Shape of the waveform input, `[slots, samples]`.
    ///   - mask: Shape of the mask input, `[slots, frames]`.
    ///   - embedding: Shape of the embedding output, `[slots, dimension]`.
    /// - Throws: ``SpeakerEmbedderError/incompatibleModel(_:)`` if the shapes
    ///   aren't rank 2 with positive sizes and one shared slot count.
    public init(waveform: [Int], mask: [Int], embedding: [Int]) throws(SpeakerEmbedderError) {
        for (name, shape) in [("waveform", waveform), ("mask", mask), ("embedding", embedding)] {
            guard shape.count == 2, shape.allSatisfy({ $0 > 0 }) else {
                throw .incompatibleModel("\(name) has shape \(shape); expected [slots, n]")
            }
        }
        guard waveform[0] == mask[0], mask[0] == embedding[0] else {
            throw .incompatibleModel(
                "Slot counts differ: waveform \(waveform[0]), mask \(mask[0]), embedding \(embedding[0])")
        }
        self.init(slotCount: waveform[0], sampleCount: waveform[1], maskFrameCount: mask[1], dimension: embedding[1])
    }
}

/// A speaker-embedding network: one model run over one waveform.
///
/// ``WeSpeakerEmbedder`` does the planning (validation, windows, splitting
/// long audio, normalization); a network only runs the model. The live one
/// is ``CoreMLSpeakerEmbeddingNetwork``; tests use fakes.
public protocol SpeakerEmbeddingNetwork: Sendable {
    /// The model's tensor layout.
    var shape: SpeakerEmbeddingNetworkShape { get }

    /// Runs the model once.
    ///
    /// - Parameter waveform: 16 kHz speech, `1...shape.sampleCount` samples.
    ///   Shorter input is padded by the network (see
    ///   ``SpeakerEmbeddingInput/tile(_:into:)``).
    /// - Returns: The raw (not normalized) embedding, `shape.dimension`
    ///   values.
    func embed(_ waveform: [Float]) async throws -> [Float]
}

/// How a waveform shorter than the network's fixed length is laid out.
public enum SpeakerEmbeddingInput {
    /// Fills `destination` with `source` repeated end to end (the last copy
    /// cut short).
    ///
    /// This is the padding FluidAudio's `EmbeddingExtractor` uses for this
    /// model. Zero padding would distort the result: the network subtracts
    /// the mean filterbank feature of the whole 10 s window from every
    /// frame, so silence would shift every frame's features. Repeating the
    /// speech keeps those statistics, and the mask-weighted pooling over an
    /// all-ones mask, the same as the original audio's.
    ///
    /// - Precondition: `source` is not empty and fits in `destination`.
    public static func tile(_ source: UnsafeBufferPointer<Float>, into destination: UnsafeMutableBufferPointer<Float>) {
        precondition(!source.isEmpty, "Nothing to tile")
        precondition(source.count <= destination.count, "Source is longer than the destination")
        guard let base = destination.baseAddress, let sourceBase = source.baseAddress else { return }
        base.update(from: sourceBase, count: source.count)
        // Double the filled prefix until the buffer is full: O(log n) copies.
        var filled = source.count
        while filled < destination.count {
            let count = min(filled, destination.count - filled)
            (base + filled).update(from: base, count: count)
            filled += count
        }
    }
}
