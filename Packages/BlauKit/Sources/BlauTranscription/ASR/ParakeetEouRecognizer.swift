// `AVAudioPCMBuffer` isn't `Sendable`. Each buffer here is built for one call into
// FluidAudio's actor and never touched again, which region checking can't see
// through `makeBuffer`.
@preconcurrency import AVFAudio
import BlauCore
import BlauTelemetry
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Synchronization

/// Parakeet realtime EOU 120M through FluidAudio's `StreamingEouAsrManager`:
/// streaming partials and a built-in end-of-utterance detector, on the
/// Neural Engine.
///
/// ```swift
/// guard let directory = modelManager.directory(for: .parakeetRealtimeEOU) else { return }
/// let recognizer = try await ParakeetEouRecognizer.load(modelDirectory: directory)
/// ```
///
/// **One chunk per model call.** `append(_:)` hands FluidAudio exactly as
/// much audio as completes the next chunk, so each `process` call runs at
/// most one chunk. That makes every `asr.chunk` signpost one chunk, lets
/// the partial and end-of-utterance callbacks be read per chunk, and stops
/// at the chunk that confirms the end of the utterance instead of decoding
/// the next utterance's audio into this one. The buffer arithmetic mirrors
/// FluidAudio 0.17.5's `process(audioBuffer:)` (it runs a chunk whenever its
/// buffer holds `chunkSamples`, then drops `shiftSamples`).
///
/// **Reset after every utterance.** FluidAudio keeps every token since the
/// last `reset()` and re-decodes all of them for each partial; its
/// `finish()` clears the tokens but keeps the confirmed end-of-utterance
/// flag (so no later end would fire) and the encoder caches. The
/// transcriber calls `reset()` after each committed utterance, so the work
/// per chunk stays flat over an hour.
///
/// **End of utterance.** FluidAudio confirms the end once
/// `eouDebounceMs` of audio has been decoded since the model's EOU token
/// with no new words. The debounce is counted in decoded audio, so it
/// rounds up to whole chunks (320 ms each at `ms320`).
public actor ParakeetEouRecognizer: StreamingSpeechRecognizer {
    public nonisolated let chunkSize: ASRChunkSize
    /// The end-of-utterance debounce the manager was created with.
    public nonisolated let endOfUtteranceDebounce: Duration

    private let manager: StreamingEouAsrManager
    private let callbacks = CallbackInbox()
    private let format: AVAudioFormat
    private let signposter: Signposter
    private let clock: any BlauClock

    /// Samples in FluidAudio's buffer (its `audioBuffer.count`).
    private var buffered = 0
    /// Audio decoded since the last reset (chunks × shift).
    private var decodedSamples: Int64 = 0
    private var transcript = ""
    private var lastTokenEnd: Int64?

    /// The default debounce: two 320 ms chunks of silence after the EOU
    /// token (see docs/asr.md for why not the 800 ms first proposed).
    public static let defaultEndOfUtteranceDebounce: Duration = .milliseconds(640)

    /// Wraps a manager whose models are loaded. The recognizer installs
    /// its own partial and end-of-utterance callbacks on it and owns it from
    /// now on.
    ///
    /// - Parameters:
    ///   - manager: A `StreamingEouAsrManager` after `loadModels(from:)`.
    ///   - chunkSize: The size the manager was created with.
    ///   - signposter: Where the `asr.chunk` intervals go.
    ///   - clock: Measures model time.
    public init(
        manager: StreamingEouAsrManager,
        chunkSize: ASRChunkSize,
        signposter: Signposter = Signposts.asr,
        clock: any BlauClock = SystemClock()
    ) async {
        self.manager = manager
        self.chunkSize = chunkSize
        self.signposter = signposter
        self.clock = clock
        self.endOfUtteranceDebounce = .milliseconds(await manager.eouDebounceMs)
        // 16 kHz mono Float32, non-interleaved: FluidAudio's converter
        // passes it through without resampling.
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFrame.captureSampleRate), channels: 1,
            interleaved: false)!
        let callbacks = self.callbacks
        await manager.setPartialCallback { callbacks.partial($0) }
        await manager.setEouCallback { callbacks.endOfUtterance($0) }
    }

    /// Loads the models from an installed `.parakeetRealtimeEOU` directory
    /// (`ModelManager.directory(for:)`), on the compute units `ModelManager`
    /// warmed them up for (Neural Engine with CPU fallback). Never use
    /// FluidAudio's downloading loader (docs/models.md).
    ///
    /// - Parameters:
    ///   - modelDirectory: The directory holding `streaming_encoder.mlmodelc`,
    ///     `decoder.mlmodelc`, `joint_decision.mlmodelc` and `vocab.json` for
    ///     `chunkSize`.
    ///   - chunkSize: The export in the directory. Blau installs `ms320`.
    ///   - endOfUtteranceDebounce: Silence after the model's EOU token before
    ///     the end is confirmed.
    ///   - computeUnits: Override for the compute units, for example
    ///     `.cpuOnly` where the Neural Engine is not available.
    /// - Throws: Core ML's error if a bundle is missing or can't load.
    public static func load(
        modelDirectory: URL,
        chunkSize: ASRChunkSize = .ms320,
        endOfUtteranceDebounce: Duration = defaultEndOfUtteranceDebounce,
        computeUnits: MLComputeUnits? = nil,
        signposter: Signposter = Signposts.asr,
        clock: any BlauClock = SystemClock()
    ) async throws -> ParakeetEouRecognizer {
        let configuration = MLModelConfiguration()
        configuration.computeUnits =
            computeUnits
            ?? CoreMLModelWarmer.computeUnits(for: .parakeetRealtimeEOU, bundle: ModelNames.ParakeetEOU.encoderFile)
            .coreML
        let debounceMs = Int((endOfUtteranceDebounce / .milliseconds(1)).rounded())
        let manager = StreamingEouAsrManager(
            configuration: configuration, chunkSize: chunkSize.fluidAudio, eouDebounceMs: debounceMs)
        try await manager.loadModels(from: modelDirectory)
        return await ParakeetEouRecognizer(
            manager: manager, chunkSize: chunkSize, signposter: signposter, clock: clock)
    }

    // MARK: StreamingSpeechRecognizer

    public func append(_ frame: AudioFrame) async throws -> RecognizerOutput {
        precondition(frame.sampleRate == AudioFrame.captureSampleRate, "Parakeet takes 16 kHz audio")
        var output = RecognizerOutput(transcript: transcript, decodedSamples: decodedSamples)
        let samples = frame.samples
        var index = 0
        while index < samples.count {
            // Exactly what completes the next chunk, or everything left.
            let take = min(chunkSize.windowSamples - buffered, samples.count - index)
            let buffer = try makeBuffer(samples[index..<(index + take)])
            index += take

            guard buffered + take >= chunkSize.windowSamples else {
                // Not a whole chunk yet: only buffer it.
                try await manager.appendAudio(buffer)
                buffered += take
                continue
            }

            callbacks.clear()
            let started = clock.uptime
            _ = try await signposter.withInterval(.asrChunk) {
                try await manager.process(audioBuffer: buffer)
            }
            output.modelTime += clock.uptime - started
            output.chunks += 1
            buffered = chunkSize.windowSamples - chunkSize.shiftSamples
            decodedSamples += Int64(chunkSize.shiftSamples)

            let fired = callbacks.take()
            if let partial = fired.partial {
                transcript = partial
                output.hasNewText = true
                lastTokenEnd = await tokenEnd()
            }
            if let final = fired.endOfUtterance {
                transcript = final
                output.isEndOfUtterance = true
                break
            }
        }
        output.consumedSamples = index
        output.transcript = transcript
        output.decodedSamples = decodedSamples
        output.lastTokenEnd = lastTokenEnd
        return output
    }

    public func finish() async throws -> RecognizerOutput {
        var output = RecognizerOutput()
        let started = clock.uptime
        let text: String
        if buffered > 0 {
            // FluidAudio pads the rest to a whole chunk and decodes it.
            text = try await signposter.withInterval(.asrChunk) { try await manager.finish() }
            output.chunks = 1
            decodedSamples += Int64(buffered)
        } else {
            text = try await manager.finish()
        }
        callbacks.clear()
        output.modelTime = clock.uptime - started
        buffered = 0
        if text != transcript {
            // `finish()` clears FluidAudio's token timestamps along with the
            // tokens, so the new words can only be placed at the end of the
            // decoded audio.
            output.hasNewText = true
            lastTokenEnd = decodedSamples
        }
        transcript = text
        output.transcript = text
        output.decodedSamples = decodedSamples
        output.lastTokenEnd = lastTokenEnd
        return output
    }

    public func reset() async {
        await manager.reset()
        callbacks.clear()
        buffered = 0
        decodedSamples = 0
        transcript = ""
        lastTokenEnd = nil
    }

    /// Releases the Core ML models. The recognizer can't be used afterwards.
    public func unload() async {
        await manager.cleanup()
    }

    // MARK: Internals

    /// The end of the newest token, in samples since the last reset.
    private func tokenEnd() async -> Int64? {
        guard let lastMs = await manager.getTokenTimestampsMs().last else { return nil }
        let rate = Int64(AudioFrame.captureSampleRate)
        return Int64(lastMs) * rate / 1_000 + Int64(chunkSize.frameSamples)
    }

    /// The samples as a 16 kHz mono `AVAudioPCMBuffer`. Built inside an
    /// autorelease pool so the Objective-C objects of each chunk are released
    /// with it, not at the end of the session.
    private func makeBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        try autoreleasepool {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else {
                throw ParakeetRecognizerError.bufferAllocationFailed(samples.count)
            }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: source.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            return buffer
        }
    }
}

/// Errors from `ParakeetEouRecognizer` itself (FluidAudio and Core ML
/// errors pass through unchanged).
public enum ParakeetRecognizerError: Error, Hashable, Sendable {
    /// An audio buffer for `sampleCount` samples couldn't be allocated.
    case bufferAllocationFailed(Int)
}

extension ASRChunkSize {
    /// FluidAudio's matching chunk size.
    var fluidAudio: StreamingChunkSize {
        switch self {
        case .ms160: .ms160
        case .ms320: .ms320
        case .ms1280: .ms1280
        }
    }
}

/// Collects what FluidAudio's callbacks report during one `process` call.
/// The callbacks run synchronously on the manager's actor, so they can't
/// call back into the recognizer; they drop the text here instead.
private final class CallbackInbox: Sendable {
    private struct Fired {
        var partial: String?
        var endOfUtterance: String?
    }

    private let state = Mutex(Fired())

    func partial(_ text: String) {
        state.withLock { $0.partial = text }
    }

    func endOfUtterance(_ text: String) {
        state.withLock { $0.endOfUtterance = text }
    }

    func clear() {
        state.withLock { $0 = Fired() }
    }

    func take() -> (partial: String?, endOfUtterance: String?) {
        state.withLock { state in
            defer { state = Fired() }
            return (state.partial, state.endOfUtterance)
        }
    }
}
