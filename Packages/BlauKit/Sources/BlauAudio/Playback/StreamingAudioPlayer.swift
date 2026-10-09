import AVFAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Plays Grok's streamed reply audio (24 kHz mono PCM16 deltas) smoothly,
/// and stops it at once on barge-in.
///
/// ```swift
/// let player = StreamingAudioPlayer()
/// await audio.register(player)          // AudioSessionController, same engine as capture
/// await audio.start()
///
/// // response.output_audio.delta
/// try player.enqueue(base64: event.delta, item: PlaybackItemID(itemID: event.itemID, contentIndex: event.contentIndex))
/// // response.output_audio.done
/// player.finish(item)
///
/// // Barge-in: stop the audio, then tell the server what was heard.
/// let cut = player.flush()
/// if let heard = cut.current {
///     send(.conversationItemTruncate(itemID: heard.id.itemID, contentIndex: heard.id.contentIndex,
///                                    audioEndMs: heard.playedMilliseconds))
/// }
/// ```
///
/// **Graph.** `install(on:)` attaches an `AVAudioSourceNode` at the
/// stream's rate (24 kHz float, the mono stream on both channels; see
/// `makeFormat()`) to the engine's main mixer, which
/// converts to the hardware format. It is the same voice-processing engine
/// that captures the microphone, so the echo canceller gets the playback as
/// its reference signal.
///
/// **Jitter buffer.** A response starts playing once `prerollDuration`
/// (120 ms) is queued, or as soon as `finish` says no more is coming. If the
/// queue runs dry while the item is still streaming, that is an underrun:
/// the node renders silence and waits for `rebufferDuration` before
/// resuming. Nothing is dropped or reordered, so a stream that keeps ahead of
/// real time plays back gaplessly, across deltas and across items.
///
/// **Played time.** Frames are counted per item as the node renders them,
/// so `playedItem(for:)` and `flush()` report exactly what reached the
/// output (preroll and underrun silence excluded), for
/// `conversation.item.truncate`.
///
/// **Flush.** `flush()` empties the queue immediately. The next render
/// cycle (at most one I/O buffer, 20 ms) plays a 5 ms fade-out of what was
/// playing and then silence. Late deltas for the flushed items are dropped.
///
/// **Threads.** Every method can be called from any thread or actor. The
/// render callback shares one short lock with them and never allocates.
public final class StreamingAudioPlayer: AudioGraphComponent {
    public let configuration: PlaybackConfiguration

    private let renderer: PlaybackRenderer
    private let clock: any BlauClock
    private let logger = Log.audio

    private struct ProducerState {
        /// One decoder per item, so an odd byte never leaks into another
        /// item's stream.
        var decoders: [PlaybackItemID: PCM16Decoder] = [:]
        var loggedUnderruns = 0
    }

    private let producer = Mutex(ProducerState())
    private let node = Mutex<AVAudioSourceNode?>(nil)

    /// - Parameters:
    ///   - configuration: Stream format and jitter-buffer settings.
    ///   - clock: Paces `updates(every:)` and stamps each item's first
    ///     rendered frame (`PlayedItem.firstRenderedAt`).
    ///   - signposter: Where `playback.firstBuffer` goes.
    public init(
        configuration: PlaybackConfiguration = .realtime,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.audio
    ) {
        self.configuration = configuration
        self.clock = clock
        renderer = PlaybackRenderer(configuration: configuration, signposter: signposter, clock: clock)
    }

    // MARK: Feeding audio

    /// Queues one base64 PCM16 delta (`response.output_audio.delta`).
    ///
    /// - Throws: `PlaybackError.invalidBase64`; nothing is queued then.
    @discardableResult
    public func enqueue(base64 delta: String, item: PlaybackItemID) throws(PlaybackError) -> EnqueueResult {
        guard let data = Data(base64Encoded: delta) else {
            logger.error("Dropped an audio delta for \(item, privacy: .public): invalid base64")
            throw .invalidBase64
        }
        return enqueue(pcm16: data, item: item)
    }

    /// Queues raw little-endian PCM16 bytes (a binary audio frame).
    @discardableResult
    public func enqueue(pcm16 bytes: Data, item: PlaybackItemID) -> EnqueueResult {
        let samples = producer.withLock { state in
            state.decoders[item, default: PCM16Decoder()].decode(bytes)
        }
        return enqueue(samples: samples, item: item)
    }

    /// Queues float samples in the stream's sample rate, in `-1...1`.
    @discardableResult
    public func enqueue(samples: [Float], item: PlaybackItemID) -> EnqueueResult {
        let result = renderer.enqueue(samples, for: item)
        switch result {
        case .queued:
            logUnderruns()
        case .droppedStaleItem:
            logger.debug("Dropped a late audio delta for flushed or finished item \(item, privacy: .public)")
        case .empty:
            break
        }
        return result
    }

    /// Says no more audio is coming for `item` (`response.output_audio.done`
    /// or `response.done`). Its queued audio plays out even if it is shorter
    /// than the jitter buffer, and running dry afterwards is the end of
    /// speech, not an underrun.
    public func finish(_ item: PlaybackItemID) {
        producer.withLock { state in
            _ = state.decoders.removeValue(forKey: item)
        }
        renderer.finish(item)
    }

    // MARK: Barge-in

    /// Stops playback within one render cycle and drops everything queued.
    ///
    /// - Returns: The items that were cut off, with how much of each was
    ///   played (the 5 ms fade-out included). Use `current` for
    ///   `conversation.item.truncate`.
    @discardableResult
    public func flush() -> PlaybackFlushResult {
        let result = renderer.flush()
        producer.withLock { state in
            for item in result.interrupted {
                state.decoders[item.id] = nil
            }
        }
        if let current = result.current {
            logger.notice(
                """
                Flushed playback: \(current.id, privacy: .public) at \(current.playedMilliseconds, privacy: .public) ms \
                of \(current.receivedFrames * 1000 / Int64(self.configuration.sampleRate), privacy: .public) ms \
                received; dropped \(result.droppedDuration.sampleCount(sampleRate: 1000), privacy: .public) ms
                """
            )
        }
        return result
    }

    // MARK: Observing

    /// How much of `item` has been played. `nil` once it has left the
    /// history (`itemHistoryCapacity` newer items).
    public func playedItem(for item: PlaybackItemID) -> PlayedItem? {
        renderer.playedItem(for: item)
    }

    /// The current state, level and queue depth.
    public var snapshot: PlaybackSnapshot { renderer.snapshot }

    /// Snapshots for the "agent speaking" indicator: the current one at
    /// once, then one every `interval` whenever it changed (the level
    /// changes every cycle while audio plays). Cancel the iterating task to
    /// stop.
    ///
    /// The render thread can't post to a stream without risking a glitch,
    /// so the stream samples the player at `interval` instead.
    public func updates(every interval: Duration = .milliseconds(50)) -> AsyncStream<PlaybackSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let clock = clock
        let initial = snapshot
        continuation.yield(initial)
        let task = Task { [weak self] in
            var last = initial
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    break
                }
                guard let self else { break }
                let current = self.snapshot
                if current != last {
                    continuation.yield(current)
                    last = current
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Rendering

    /// Renders the next `output.count` frames of mono audio at the stream's
    /// sample rate. The source node calls this; tests and offline hosts can
    /// too.
    ///
    /// - Returns: Whether the frames are all silence.
    @discardableResult
    public func render(into output: UnsafeMutableBufferPointer<Float>) -> Bool {
        renderer.render(into: output)
    }

    /// The format the source node renders: two identical channels of
    /// 32-bit float, non-interleaved, at the stream's sample rate.
    ///
    /// The stream is mono, but a mono input to `AVAudioMixerNode` plays at
    /// unity gain only the first time it is connected; reconnected after a
    /// graph rebuild (every route change), the mixer pans it at -3 dB. A
    /// stereo input stays at unity gain on stereo and mono outputs alike,
    /// so the agent's volume doesn't drop when AirPods connect.
    public func makeFormat() -> AVAudioFormat {
        // Only fails for invalid parameters; these are always valid.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.sampleRate),
            channels: 2,
            interleaved: false
        )!
    }

    // MARK: AudioGraphComponent

    public func install(on engine: AVAudioEngine) throws {
        let format = makeFormat()
        let renderer = renderer
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count > 0, let first = buffers[0].mData, frames > 0 else {
                isSilence.pointee = true
                return noErr
            }
            let mono = first.assumingMemoryBound(to: Float.self)
            let silent = renderer.render(into: UnsafeMutableBufferPointer(start: mono, count: frames))
            // The stream is mono; every channel gets the same samples.
            var index = 1
            while index < buffers.count {
                if let data = buffers[index].mData {
                    data.assumingMemoryBound(to: Float.self).update(from: mono, count: frames)
                }
                index += 1
            }
            isSilence.pointee = ObjCBool(silent)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // After a media-services reset the previous node belongs to a dead
        // engine; just drop the reference.
        node.withLock { $0 = source }
        logger.info(
            """
            Playback node installed: \(self.configuration.sampleRate, privacy: .public) Hz into \
            \(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz mixer
            """
        )
    }

    public func uninstall(from engine: AVAudioEngine) {
        let source = node.withLock { node -> AVAudioSourceNode? in
            let current = node
            node = nil
            return current
        }
        guard let source, engine.attachedNodes.contains(source) else { return }
        engine.disconnectNodeOutput(source)
        engine.detach(source)
        // Queued audio is kept: after a rebuild it carries on where it was.
        renderer.resetLevel()
    }

    // MARK: Logging

    /// Underruns happen on the render thread, which can't log; report them
    /// when the late audio arrives.
    private func logUnderruns() {
        let underruns = renderer.snapshot.underrunCount
        let new = producer.withLock { state -> Int in
            let new = underruns - state.loggedUnderruns
            state.loggedUnderruns = max(state.loggedUnderruns, underruns)
            return new
        }
        if new > 0 {
            logger.error("Playback underrun: the audio queue ran dry \(new, privacy: .public) time(s); rebuffering")
        }
    }
}
