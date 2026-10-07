import AVFAudio
import AudioToolbox
import BlauCore
import Synchronization

/// Apple's voice isolation model as a noise suppressor: the `AUSoundIsolation`
/// audio unit (iOS 16+, macOS 13+), the system's neural speech isolation,
/// run on Blau's 16 kHz stream.
///
/// It needs no download and Apple maintains it. It is not the Voice
/// Isolation **mic mode** (which the user picks in Control Center and the
/// system applies inside voice processing, ``MicrophoneModeSource``), but
/// the same kind of processing under the app's control, so the evaluation
/// can compare it with DeepFilterNet3 on the same audio.
///
/// The unit runs in an `AVAudioEngine` in offline manual-rendering mode: a
/// source node feeds it the samples handed to `process(_:)`, and the engine
/// renders exactly that many samples back. The output lags the input by the
/// unit's reported latency (about 58 ms).
///
/// Not thread-safe: one stream at a time.
public final class SoundIsolationSuppressor: NoiseSuppressor {
    /// Which of the unit's models to run.
    public enum Model: String, CaseIterable, Codable, Sendable {
        /// `kAUSoundIsolationSoundType_Voice`: the standard model.
        case voice
        /// `kAUSoundIsolationSoundType_HighQualityVoice` (iOS 18+, macOS 15+).
        case highQualityVoice

        var parameterValue: AUValue {
            switch self {
            case .voice: AUValue(kAUSoundIsolationSoundType_Voice)
            case .highQualityVoice: AUValue(kAUSoundIsolationSoundType_HighQualityVoice)
            }
        }
    }

    public let descriptor: NoiseSuppressorDescriptor
    public let model: Model
    private let engine = AVAudioEngine()
    private let effect: AVAudioUnitEffect
    private let queue = SampleQueue()
    private let buffer: AVAudioPCMBuffer
    private let maximumFrameCount: AVAudioFrameCount = 4_096

    /// The audio unit's description: Apple's `vois` effect.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Whether this OS has the audio unit.
    public static var isAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// - Parameter model: The unit's standard or high-quality voice model.
    public init(model: Model = .voice) throws {
        guard Self.isAvailable else {
            throw NoiseSuppressionError.audioUnitFailed("AUSoundIsolation isn't available on this OS")
        }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFrame.captureSampleRate), channels: 1,
                interleaved: false)
        else { throw NoiseSuppressionError.audioUnitFailed("No 16 kHz mono format") }
        self.model = model
        effect = AVAudioUnitEffect(audioComponentDescription: Self.componentDescription)
        let queue = queue
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            queue.dequeue(into: UnsafeMutableBufferPointer(start: data, count: Int(frameCount)))
            return noErr
        }
        engine.attach(source)
        engine.attach(effect)
        engine.connect(source, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
        } catch {
            throw NoiseSuppressionError.audioUnitFailed("Manual rendering: \(error)")
        }
        let status = AudioUnitSetParameter(
            effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0,
            model.parameterValue, 0)
        guard status == noErr else {
            throw NoiseSuppressionError.audioUnitFailed("Can't select the \(model.rawValue) model (\(status))")
        }
        do {
            try engine.start()
        } catch {
            throw NoiseSuppressionError.audioUnitFailed("Engine start: \(error)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrameCount)
        else { throw NoiseSuppressionError.audioUnitFailed("No render buffer") }
        self.buffer = buffer
        // The latency is known once the unit is initialized (the engine
        // started it).
        let latency = Int((effect.auAudioUnit.latency * Double(AudioFrame.captureSampleRate)).rounded())
        descriptor = NoiseSuppressorDescriptor(
            id: model == .voice ? "apple-voice-isolation" : "apple-voice-isolation-hq",
            title: model == .voice
                ? "Apple AUSoundIsolation, voice model" : "Apple AUSoundIsolation, high-quality voice model",
            latencySamples: latency,
            settings: ["audioUnit": "AUSoundIsolation", "model": model.rawValue])
    }

    deinit {
        engine.stop()
    }

    public func process(_ samples: [Float]) throws -> [Float] {
        queue.enqueue(samples)
        return try render(samples.count)
    }

    public func finish() throws -> [Float] {
        defer { reset() }
        let tail = descriptor.latencySamples
        queue.enqueue([Float](repeating: 0, count: tail))
        return try render(tail)
    }

    public func reset() {
        queue.removeAll()
        engine.reset()
        effect.auAudioUnit.reset()
    }

    /// Renders `count` samples, as the source node supplies them.
    private func render(_ count: Int) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, Int(maximumFrameCount)))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(frames, to: buffer)
            } catch {
                throw NoiseSuppressionError.audioUnitFailed("Render: \(error)")
            }
            guard status == .success, let channel = buffer.floatChannelData?[0] else {
                throw NoiseSuppressionError.audioUnitFailed("Render status \(status.rawValue)")
            }
            output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            remaining -= Int(buffer.frameLength)
        }
        return output
    }
}

/// Samples waiting for the source node's render callback. The callback runs
/// on the thread that calls `renderOffline`, but it is an escaping closure,
/// so the queue is locked rather than shared unprotected.
private final class SampleQueue: Sendable {
    private let samples = Mutex<[Float]>([])

    func enqueue(_ new: [Float]) {
        samples.withLock { $0.append(contentsOf: new) }
    }

    /// Fills `destination`, with silence past what is queued.
    func dequeue(into destination: UnsafeMutableBufferPointer<Float>) {
        samples.withLock { samples in
            let count = min(samples.count, destination.count)
            for index in 0..<count { destination[index] = samples[index] }
            for index in count..<destination.count { destination[index] = 0 }
            samples.removeFirst(count)
        }
    }

    func removeAll() {
        samples.withLock { $0.removeAll() }
    }
}
