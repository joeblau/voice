import AVFAudio
import BlauCore
import BlauTelemetry
import Synchronization
import os

/// The mic capture engine: an `AudioGraphComponent` that receives the
/// voice-processed microphone signal, converts it to 16 kHz mono off the
/// real-time thread and fans it out through `hub`.
///
/// ```swift
/// let capture = MicrophoneCapture()
/// let audio = AudioSessionController.live()
/// await audio.register(capture)
/// await audio.start()
/// for await frame in capture.hub.frames() { ... }
/// ```
///
/// **Pipeline.**
/// 1. *Audio I/O thread.* An `AVAudioSinkNode` connected to the input node
///    gets each hardware buffer (about 20 ms with the session's I/O buffer
///    duration). `CaptureProducer` downmixes it to mono straight into a
///    preallocated lock-free SPSC ring and signals a semaphore. No
///    allocation, no locks, no Objective-C or Swift runtime calls: the
///    write path is compiler-checked with `@_noLocks`. If the ring is full
///    the buffer is dropped and counted.
/// 2. *Capture thread.* Wakes on the semaphore, resamples with
///    `AVAudioConverter` (48 kHz → 16 kHz; a pass-through when the route
///    already runs at 16 kHz), stamps host time and sample offset, and
///    appends to the hub inside a `capture.frame` signpost interval.
/// 3. *Hub.* Re-chunks into 20 ms `AudioFrame`s, keeps 30 s of history,
///    and yields the same frames to every subscriber plus input levels for
///    the meter.
///
/// Every graph build (start, resume after an interruption, route change,
/// media-services reset) starts a new capture segment that reads the
/// current hardware format. The stream continues across segments; see
/// `CaptureHub`.
public final class MicrophoneCapture: AudioGraphComponent {
    /// How audio is taken from the input node.
    public enum InputMode: String, Sendable, Hashable, CaseIterable {
        /// `AVAudioSinkNode`: buffers arrive on the real-time I/O thread at
        /// the I/O buffer size (~20 ms). The default.
        case sinkNode
        /// `installTap` on the input node: buffers arrive on an internal
        /// non-real-time thread in 100–400 ms blocks. Higher latency; a
        /// fallback if the sink node misbehaves on some route.
        case tap
    }

    public struct Configuration: Sendable, Hashable {
        public var inputMode: InputMode
        /// How much hardware-rate audio the ring holds before the audio
        /// thread starts dropping buffers. The capture thread normally
        /// drains it every ~20 ms; this is slack for scheduling hiccups.
        public var ringBufferDuration: Duration
        /// Tap buffer size in `.tap` mode (AVAudioEngine allows 100–400 ms).
        public var tapBufferDuration: Duration

        public init(
            inputMode: InputMode = .sinkNode,
            ringBufferDuration: Duration = .seconds(2),
            tapBufferDuration: Duration = .milliseconds(100)
        ) {
            precondition(ringBufferDuration > .zero, "The ring must hold some audio")
            precondition(tapBufferDuration > .zero, "Tap buffers must hold some audio")
            self.inputMode = inputMode
            self.ringBufferDuration = ringBufferDuration
            self.tapBufferDuration = tapBufferDuration
        }

        public static let standard = Configuration()
    }

    /// The format capture is reading from the input node, for diagnostics.
    public struct InputFormat: Sendable, Hashable {
        public var sampleRate: Double
        public var channelCount: Int
        public var isVoiceProcessed: Bool
    }

    /// Where captured audio goes. Subscribe here.
    public let hub: CaptureHub
    public let configuration: Configuration

    private struct Installation {
        let segment: CaptureSegment
        let format: InputFormat
        /// The sink node in `.sinkNode` mode.
        let sinkNode: AVAudioSinkNode?
        /// The node holding the tap in `.tap` mode.
        let tappedNode: AVAudioInputNode?
    }

    private struct State {
        var installation: Installation?
        /// The most recent segment, open or closed: the next segment's
        /// thread waits for it.
        var lastSegment: CaptureSegment?
    }

    private let state = Mutex(State())
    private let signposter: Signposter
    private let logger = Log.audio

    /// - Parameters:
    ///   - hub: Receives the audio. Pass one in to share it or configure it.
    ///   - configuration: Input mode and buffer sizes.
    ///   - signposter: Where `capture.frame` intervals and `capture.drop`
    ///     events go.
    public init(
        hub: CaptureHub? = nil,
        configuration: Configuration = .standard,
        signposter: Signposter = Signposts.audio
    ) {
        self.hub = hub ?? CaptureHub(signposter: signposter)
        self.configuration = configuration
        self.signposter = signposter
    }

    deinit {
        let segments = state.withLock { state in
            [state.installation?.segment, state.lastSegment]
        }
        for segment in segments {
            segment?.close()
        }
    }

    /// The input format of the current installation, `nil` when not
    /// installed.
    public var inputFormat: InputFormat? {
        state.withLock { $0.installation?.format }
    }

    // MARK: AudioGraphComponent

    public func install(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputAvailable(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureError.unsupportedInputFormat(format.description)
        }
        // Fail here, where the controller reports it, rather than on the
        // capture thread.
        _ = try CaptureResampler(inputSampleRate: format.sampleRate, outputSampleRate: Double(hub.sampleRate))

        let inputFormat = InputFormat(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            isVoiceProcessed: input.isVoiceProcessingEnabled
        )
        let ringSamples = Int(
            configuration.ringBufferDuration.sampleCount(sampleRate: Int(format.sampleRate.rounded())))
        let tapFrames = Int(configuration.tapBufferDuration.sampleCount(sampleRate: Int(format.sampleRate.rounded())))
        let producer = CaptureProducer(
            sampleCapacity: max(ringSamples, tapFrames * 2, 1),
            // Generous: even 2 ms buffers fit for the ring's whole duration.
            chunkCapacity: 1_024,
            downmix: inputFormat.isVoiceProcessed ? .firstChannel : .average
        )
        let segment = CaptureSegment(producer: producer, inputSampleRate: format.sampleRate)

        var sinkNode: AVAudioSinkNode?
        var tappedNode: AVAudioInputNode?
        switch configuration.inputMode {
        case .sinkNode:
            let node = Self.makeSinkNode(producer: producer)
            engine.attach(node)
            engine.connect(input, to: node, format: format)
            sinkNode = node
        case .tap:
            Self.installTap(on: input, frames: tapFrames, format: format, producer: producer)
            tappedNode = input
        }

        let (stale, previous) = state.withLock { state in
            // After a media-services reset `install` comes without an
            // `uninstall` on the dead engine: that segment is still open.
            let stale = state.installation?.segment
            state.installation = Installation(
                segment: segment, format: inputFormat, sinkNode: sinkNode, tappedNode: tappedNode)
            let previous = state.lastSegment
            state.lastSegment = segment
            return (stale, previous)
        }
        stale?.close()
        segment.start(hub: hub, signposter: signposter, after: previous)

        logger.notice(
            """
            Capture installed (\(self.configuration.inputMode.rawValue, privacy: .public)): \
            \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, \
            voice processing \(inputFormat.isVoiceProcessed, privacy: .public)
            """
        )
    }

    public func uninstall(from engine: AVAudioEngine) {
        guard let installation = state.withLock({ $0.installation.take() }) else { return }
        if let sinkNode = installation.sinkNode {
            engine.disconnectNodeInput(sinkNode)
            engine.detach(sinkNode)
        }
        if let tappedNode = installation.tappedNode {
            tappedNode.removeTap(onBus: 0)
        }
        installation.segment.close()
    }

    /// Blocks until every capture thread started so far has drained and
    /// exited. For tests and shutdown paths that need all audio delivered;
    /// call it after `uninstall`.
    public func waitUntilDrained() {
        state.withLock { $0.lastSegment }?.waitUntilFinished()
    }

    // MARK: Nodes

    private static func makeSinkNode(producer: CaptureProducer) -> AVAudioSinkNode {
        AVAudioSinkNode(receiverBlock: sinkReceiver(producer: producer))
    }

    /// The sink node's receiver. It runs on the real-time I/O thread and
    /// only touches the producer, captured once here; see
    /// `CaptureProducer.receive`. Separate so tests can call it.
    static func sinkReceiver(producer: CaptureProducer) -> AVAudioSinkNodeReceiverBlock {
        { timestamp, frameCount, bufferList in
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : 0
            producer.receive(bufferList, frameCount: Int(frameCount), hostTime: hostTime)
            return noErr
        }
    }

    private static func installTap(
        on input: AVAudioInputNode,
        frames: Int,
        format: AVAudioFormat,
        producer: CaptureProducer
    ) {
        let block: AVAudioNodeTapBlock = { buffer, when in
            producer.receive(
                buffer.audioBufferList,
                frameCount: Int(buffer.frameLength),
                hostTime: when.isHostTimeValid ? when.hostTime : 0
            )
        }
        // The SDK 27 replacement, `installTapOnBus:bufferSize:format:error:block:`,
        // is NS_REFINED_FOR_SWIFT with no public Swift spelling yet, so this
        // is the only Swift entry point. Its deprecation starts at iOS 27,
        // above the deployment target, so it doesn't warn.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(frames, 1)), format: format, block: block)
    }
}
