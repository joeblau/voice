import BlauCore

/// The streaming chunk sizes Parakeet realtime EOU 120M was exported for,
/// with the geometry FluidAudio 0.17.5's `StreamingEouAsrManager` uses for
/// each (`StreamingChunkSize` in its `StreamingEouAsrManager.swift`).
///
/// A chunk is a window of `windowSamples` that the encoder runs on; the
/// window then moves on by `shiftSamples`, so after the first window a new
/// chunk runs every `shiftSamples` of audio and decodes `outputFrames`
/// encoder frames of it. Bigger chunks are cheaper per second of audio but
/// slower to show words.
///
/// Each size is a separate Core ML export. Blau requires the 320 ms one
/// (`ModelID.parakeetRealtimeEOU`) and downloads the 1280 ms one as an
/// optional model (`ModelID.parakeetRealtimeEOU1280`) for the thermal and
/// power policy (#75); a size is only used when a recognizer for it can be
/// loaded (see `ASRChunkSizePolicy`).
public enum ASRChunkSize: String, CaseIterable, Hashable, Sendable {
    /// A chunk every 160 ms over a 160 ms window.
    case ms160
    /// A chunk every 320 ms over a 630 ms window (Blau's default).
    case ms320
    /// A chunk every 1280 ms over a 1280 ms window: about a quarter of the
    /// model calls of `ms320`, for thermal pressure.
    case ms1280

    /// Samples the encoder sees per chunk (`StreamingChunkSize.chunkSamples`).
    public var windowSamples: Int {
        switch self {
        case .ms160: 2_560
        case .ms320: 10_080
        case .ms1280: 20_480
        }
    }

    /// Samples the window moves by after each chunk
    /// (`StreamingChunkSize.shiftSamples`): the audio each chunk decodes.
    public var shiftSamples: Int {
        switch self {
        case .ms160: 1_280
        case .ms320: 5_120
        case .ms1280: 20_480
        }
    }

    /// Encoder frames decoded per chunk (`StreamingChunkSize.validOutputLen`).
    public var outputFrames: Int {
        switch self {
        case .ms160: 2
        case .ms320: 4
        case .ms1280: 16
        }
    }

    /// How often a chunk runs once audio is flowing.
    public var shift: Duration {
        .samples(Int64(shiftSamples), sampleRate: AudioFrame.captureSampleRate)
    }

    /// Audio needed before the first chunk can run.
    public var window: Duration {
        .samples(Int64(windowSamples), sampleRate: AudioFrame.captureSampleRate)
    }

    /// The model that holds this size's export, or `nil` when Blau doesn't
    /// install it (160 ms, see docs/benchmarks.md).
    public var modelID: ModelID? {
        switch self {
        case .ms160: nil
        case .ms320: .parakeetRealtimeEOU
        case .ms1280: .parakeetRealtimeEOU1280
        }
    }

    /// The length of one decoded encoder frame (80 ms for `ms320` and
    /// `ms1280`, 40 ms for `ms160`): the resolution of token timestamps.
    public var frameSamples: Int {
        shiftSamples / outputFrames
    }
}
