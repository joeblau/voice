import BlauCore

/// DeepFilterNet3 on Blau's 16 kHz stream: upsampled to the model's 48 kHz,
/// enhanced in 10 ms hops by ``DeepFilterNet3Processor``, and resampled
/// back to 16 kHz.
///
/// The 16 kHz capture stream has nothing above 8 kHz, so the model's upper
/// ERB bands see silence. That is not the full-band audio the model is
/// usually given, so the evaluation (docs/noise-suppression.md) measures
/// the result on Blau's own stream rather than assuming it. In a live pipeline
/// the suppressor would sit before the capture resampler, at the hardware's
/// 48 kHz, and skip both conversions.
///
/// The output is the input delayed by ``latencySamples`` (30 ms of model
/// delay plus the resamplers' filters); up to one 10 ms hop more is held
/// back until it fills.
///
/// Not thread-safe: one stream at a time.
public final class DeepFilterNet3Suppressor: NoiseSuppressor {
    /// The output's delay at 16 kHz: the model's 1,440 samples at 48 kHz
    /// (480 at 16 kHz) plus the two resamplers' combined filter delay
    /// (measured, see `DeepFilterNet3SuppressorTests`).
    public static let latencySamples = 480 + resamplerDelay

    /// The 16 → 48 → 16 kHz round trip's delay through `AVAudioConverter`
    /// at `.high` quality, in 16 kHz samples.
    static let resamplerDelay = 0

    public let descriptor: NoiseSuppressorDescriptor
    private let processor: DeepFilterNet3Processor
    private let upsampler: CaptureResampler
    private let downsampler: CaptureResampler
    private var pending: [Float] = []

    /// - Parameters:
    ///   - processor: The 48 kHz signal path and network.
    ///   - settings: Recorded in the descriptor (model revision, compute
    ///     units).
    public init(processor: DeepFilterNet3Processor, settings: [String: String] = [:]) throws {
        let rate = Double(processor.parameters.sampleRate)
        do {
            upsampler = try CaptureResampler(
                inputSampleRate: Double(AudioFrame.captureSampleRate), outputSampleRate: rate)
            downsampler = try CaptureResampler(inputSampleRate: rate)
        } catch {
            throw NoiseSuppressionError.resamplingFailed("\(error)")
        }
        self.processor = processor
        descriptor = NoiseSuppressorDescriptor(
            id: "dfn3", title: "DeepFilterNet3 (Core ML, 48 kHz)", latencySamples: Self.latencySamples,
            settings: settings)
    }

    /// A suppressor over `model`, with its own network state.
    public convenience init(model: DeepFilterNet3Model) throws {
        let processor = try DeepFilterNet3Processor(parameters: model.parameters, network: try model.makeNetwork())
        try self.init(
            processor: processor,
            settings: [
                "model": "\(DeepFilterNet3Model.repository)@\(DeepFilterNet3Model.revision.prefix(8))",
                "computeUnits": model.computeUnits.rawValue,
            ])
    }

    /// The network's local SNR estimate for the last 10 ms enhanced, in dB.
    public var localSNR: Float? { processor.localSNR }

    public func process(_ samples: [Float]) throws -> [Float] {
        var upsampled: [Float] = []
        try resample(samples, with: upsampler) { upsampled.append(contentsOf: $0) }
        return try enhance(upsampled)
    }

    public func finish() throws -> [Float] {
        defer { reset() }
        var tail: [Float] = []
        do {
            try upsampler.flush { tail.append(contentsOf: $0) }
        } catch {
            throw NoiseSuppressionError.resamplingFailed("\(error)")
        }
        // Complete the last hop, then push the model's delay out with silence.
        let hop = processor.parameters.hopSize
        let partial = (pending.count + tail.count) % hop
        if partial > 0 { tail += repeatElement(0, count: hop - partial) }
        tail += repeatElement(0, count: processor.parameters.latencySamples)
        var output = try enhance(tail)
        do {
            try downsampler.flush { output.append(contentsOf: $0) }
        } catch {
            throw NoiseSuppressionError.resamplingFailed("\(error)")
        }
        return output
    }

    public func reset() {
        processor.reset()
        upsampler.reset()
        downsampler.reset()
        pending.removeAll(keepingCapacity: true)
    }

    /// Runs whole hops of 48 kHz audio through the model and returns them at
    /// 16 kHz; a partial hop waits for more.
    private func enhance(_ upsampled: [Float]) throws -> [Float] {
        pending += upsampled
        let hop = processor.parameters.hopSize
        var enhanced: [Float] = []
        var start = 0
        while pending.count - start >= hop {
            enhanced += try processor.process(hop: Array(pending[start..<(start + hop)]))
            start += hop
        }
        pending.removeFirst(start)
        var output: [Float] = []
        try resample(enhanced, with: downsampler) { output.append(contentsOf: $0) }
        return output
    }

    private func resample(
        _ samples: [Float], with resampler: CaptureResampler, emit: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
        do {
            try samples.withUnsafeBufferPointer { buffer throws(CaptureError) in
                try resampler.process(buffer, emit: emit)
            }
        } catch {
            throw NoiseSuppressionError.resamplingFailed("\(error)")
        }
    }
}
