import BlauAudio
import Foundation
import Synchronization

/// An ``AgentAudioOutput`` with no speaker: it counts the reply audio it is
/// given and treats it as heard the moment it arrives, so a reply cut off
/// by a new turn keeps everything received so far.
///
/// For replays that run the turn orchestrator without an audio engine, such
/// as the performance suite's scripted session (#73), where waiting for
/// playback in real time would only slow the run down.
public final class DiscardingAgentAudioOutput: AgentAudioOutput {
    private struct State {
        var items: [PlaybackItemID: Int64] = [:]
        var order: [PlaybackItemID] = []
        var finished: Set<PlaybackItemID> = []
        var totalBytes = 0
    }

    /// The reply audio's sample rate (PCM16 mono).
    public let sampleRate: Int
    private let state = Mutex(State())

    public init(sampleRate: Int = 24_000) {
        self.sampleRate = sampleRate
    }

    /// Reply audio received so far, in bytes.
    public var receivedBytes: Int { state.withLock { $0.totalBytes } }

    /// Items whose audio started, in order.
    public var receivedItems: [PlaybackItemID] { state.withLock { $0.order } }

    @discardableResult
    public func enqueue(pcm16 bytes: Data, item: PlaybackItemID) -> EnqueueResult {
        guard !bytes.isEmpty else { return .empty }
        return state.withLock { state in
            if state.finished.contains(item) { return .droppedStaleItem }
            if state.items[item] == nil { state.order.append(item) }
            state.items[item, default: 0] += Int64(bytes.count / 2)
            state.totalBytes += bytes.count
            return .queued
        }
    }

    public func finish(_ item: PlaybackItemID) {
        state.withLock { _ = $0.finished.insert(item) }
    }

    @discardableResult
    public func flush() -> PlaybackFlushResult {
        let interrupted = state.withLock { state in
            let open = state.order.filter { !state.finished.contains($0) }
            for item in open { state.finished.insert(item) }
            // Audio "plays" the moment it arrives, so everything received was heard.
            return open.map {
                let frames = state.items[$0] ?? 0
                return PlayedItem(id: $0, playedFrames: frames, receivedFrames: frames, sampleRate: sampleRate)
            }
        }
        return PlaybackFlushResult(interrupted: interrupted, droppedDuration: .zero)
    }

    public func playedItem(for item: PlaybackItemID) -> PlayedItem? {
        state.withLock { state in
            guard let frames = state.items[item] else { return nil }
            return PlayedItem(id: item, playedFrames: frames, receivedFrames: frames, sampleRate: sampleRate)
        }
    }

    public func waitUntilIdle() async {}
}
