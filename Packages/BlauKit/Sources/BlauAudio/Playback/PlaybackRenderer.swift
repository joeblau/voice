import Accelerate
import BlauCore
import BlauTelemetry
import Synchronization

/// The jitter buffer and render loop behind `StreamingAudioPlayer`,
/// independent of `AVAudioEngine` so it is tested sample by sample on the
/// Mac.
///
/// Producers (the realtime client's receive loop) call `enqueue`, `finish`
/// and `flush` from any thread. The audio render thread calls
/// `render(into:)` once per I/O cycle. Both sides share one `Mutex`
/// (`os_unfair_lock`, which donates priority to the render thread), and
/// every critical section is short and bounded: producers append or move
/// whole chunks, and the render thread copies at most one cycle of samples.
///
/// Real-time rules for the render path:
/// - It never allocates or frees. Chunks are allocated by producers and
///   consumed chunks are released by the next producer call, outside the
///   lock. Per-item counters live in a fixed-size array created in `init`,
///   and nothing outside the lock keeps a copy of the arrays the render
///   path writes to, so writing them never triggers a copy.
/// - It never waits on anything but the lock.
///
/// Played time is counted in frames at the stream's sample rate as they
/// are rendered, so it is exact: underrun silence and preroll are not
/// counted, and a flush credits exactly the frames of its fade-out.
final class PlaybackRenderer: Sendable {
    // MARK: Types

    /// A run of samples for one item.
    struct Chunk {
        var samples: ContiguousArray<Float>
        var slot: Int
        var sequence: UInt64
    }

    /// Bookkeeping for one response item, in a fixed ring of slots.
    struct ItemRecord {
        var id: PlaybackItemID?
        var sequence: UInt64 = 0
        var receivedFrames: Int64 = 0
        var playedFrames: Int64 = 0
        var queuedFrames: Int = 0
        /// No more audio will come: `finish` was called or it was flushed.
        var isFinished = false
        var hasStartedPlaying = false
        /// `playback.firstBuffer`, from the first enqueue to the first
        /// rendered frame. Ended by the render thread; released by
        /// producers when the slot is reused.
        var firstBuffer: SignpostInterval?
    }

    struct State {
        // Queue. `chunks[readChunk...]` is unplayed; earlier chunks are
        // consumed and released by the next producer call.
        var chunks: [Chunk] = []
        var readChunk = 0
        var readOffset = 0
        var queuedFrames = 0

        // Items.
        var items: [ItemRecord]
        var nextSequence: UInt64 = 1
        /// Producer-only index from ID to slot.
        var slots: [PlaybackItemID: Int] = [:]
        /// The item audio was last enqueued for. While it isn't finished,
        /// an empty queue is an underrun rather than the end of speech.
        var tailSlot: Int?
        var tailSequence: UInt64 = 0

        // Jitter buffer.
        var mode: PlaybackState = .idle
        var startThreshold = 0
        var waitedFrames = 0
        var underrunCount = 0

        // Flush fade-out: `fade[fadeRead..<fadeCount]` plays before
        // anything else. Allocated once in `init`.
        var fade: ContiguousArray<Float>
        var fadeCount = 0
        var fadeRead = 0

        // Output.
        var level = PlaybackLevel.silent
        var renderedFrames: Int64 = 0

        func isCurrent(slot: Int, sequence: UInt64) -> Bool {
            items[slot].sequence == sequence && items[slot].id != nil
        }

        /// Whether more audio is expected for the tail of the queue.
        var awaitingMore: Bool {
            guard let tailSlot, isCurrent(slot: tailSlot, sequence: tailSequence) else { return false }
            return !items[tailSlot].isFinished
        }
    }

    // MARK: Properties

    let configuration: PlaybackConfiguration
    private let signposter: Signposter
    private let state: Mutex<State>

    init(configuration: PlaybackConfiguration, signposter: Signposter) {
        self.configuration = configuration
        self.signposter = signposter
        state = Mutex(
            State(
                items: Array(repeating: ItemRecord(), count: configuration.itemHistoryCapacity),
                fade: ContiguousArray(repeating: 0, count: max(configuration.flushFadeFrames, 1))
            )
        )
    }

    // MARK: Producer side

    /// Queues `samples` for `id`. Starts the jitter buffer if idle.
    func enqueue(_ samples: [Float], for id: PlaybackItemID) -> EnqueueResult {
        guard !samples.isEmpty else { return .empty }
        let chunkSamples = ContiguousArray(samples)
        let frames = chunkSamples.count

        // Released after the lock: consumed chunks and anything a reused
        // slot held.
        let (result, garbage): (EnqueueResult, Garbage) = state.withLock { state in
            var garbage = Garbage(chunks: reclaimConsumedChunks(&state))

            let slot: Int
            if let existing = state.slots[id], state.items[existing].id == id {
                if state.items[existing].isFinished {
                    return (.droppedStaleItem, garbage)
                }
                slot = existing
            } else {
                (slot, garbage.interval) = registerItem(id, in: &state)
            }

            let sequence = state.items[slot].sequence
            state.chunks.append(Chunk(samples: chunkSamples, slot: slot, sequence: sequence))
            state.items[slot].receivedFrames += Int64(frames)
            state.items[slot].queuedFrames += frames
            state.queuedFrames += frames
            state.tailSlot = slot
            state.tailSequence = sequence
            if state.mode == .idle {
                state.mode = .buffering
                state.startThreshold = configuration.prerollFrames
                state.waitedFrames = 0
            }
            return (.queued, garbage)
        }
        // A recycled record's interval that never reached the speaker.
        garbage.interval?.end()
        withExtendedLifetime(garbage) {}
        return result
    }

    /// Marks `id` complete: no more audio will arrive for it
    /// (`response.output_audio.done`). Once its queued audio has played,
    /// the player goes idle instead of waiting for more.
    func finish(_ id: PlaybackItemID) {
        state.withLock { state in
            guard let slot = state.slots[id], state.items[slot].id == id else { return }
            state.items[slot].isFinished = true
        }
    }

    /// Drops everything queued. The audio that was playing fades out over
    /// `flushFadeDuration` in the next render cycle, then the output is
    /// silent. Items that were cut off are marked finished, so late deltas
    /// for them are dropped.
    func flush() -> PlaybackFlushResult {
        let (result, garbage): (PlaybackFlushResult, Garbage) = state.withLock { state in
            var order: [Int] = []
            for chunk in state.chunks[state.readChunk...]
            where state.isCurrent(slot: chunk.slot, sequence: chunk.sequence) && !order.contains(chunk.slot) {
                order.append(chunk.slot)
            }
            if state.awaitingMore, let tail = state.tailSlot, !order.contains(tail) {
                order.append(tail)
            }

            if state.mode == .playing && state.fadeRead == state.fadeCount {
                prepareFade(&state)
            }
            let dropped = state.queuedFrames

            var intervals: [SignpostInterval] = []
            let interrupted = order.map { slot in
                state.items[slot].isFinished = true
                state.items[slot].queuedFrames = 0
                if let interval = state.items[slot].firstBuffer, !state.items[slot].hasStartedPlaying {
                    intervals.append(interval)
                }
                return playedItem(state.items[slot])
            }

            let garbage = Garbage(chunks: state.chunks, endedIntervals: intervals)
            state.chunks = []
            state.readChunk = 0
            state.readOffset = 0
            state.queuedFrames = 0
            state.tailSlot = nil
            state.mode = .idle
            state.waitedFrames = 0
            state.level = .silent
            return (
                PlaybackFlushResult(
                    interrupted: interrupted,
                    droppedDuration: .samples(Int64(dropped), sampleRate: configuration.sampleRate)
                ),
                garbage
            )
        }
        // An interval that never reached the speaker ends at the flush.
        for interval in garbage.endedIntervals { interval.end() }
        withExtendedLifetime(garbage) {}
        return result
    }

    /// How much of `id` has been played, if it is still in the history.
    func playedItem(for id: PlaybackItemID) -> PlayedItem? {
        state.withLock { state in
            guard let slot = state.slots[id], state.items[slot].id == id else { return nil }
            return playedItem(state.items[slot])
        }
    }

    var snapshot: PlaybackSnapshot {
        state.withLock { state in
            var current: PlaybackItemID?
            if state.readChunk < state.chunks.count {
                let chunk = state.chunks[state.readChunk]
                if state.isCurrent(slot: chunk.slot, sequence: chunk.sequence) {
                    current = state.items[chunk.slot].id
                }
            } else if state.awaitingMore, let tail = state.tailSlot {
                current = state.items[tail].id
            }
            return PlaybackSnapshot(
                state: state.mode,
                level: state.level,
                bufferedDuration: .samples(Int64(state.queuedFrames), sampleRate: configuration.sampleRate),
                currentItem: current,
                underrunCount: state.underrunCount,
                renderedFrames: state.renderedFrames
            )
        }
    }

    /// Resets the level meter, for when the engine stops calling `render`.
    func resetLevel() {
        state.withLock { $0.level = .silent }
    }

    // MARK: Render side

    /// Fills `output` with the next `output.count` frames: the pending
    /// flush fade, then queued audio once the jitter buffer is primed, with
    /// silence for whatever is missing.
    ///
    /// Real-time safe: no allocation, no deallocation, no blocking other
    /// than the short producer critical sections. The only system call is
    /// ending an item's `playback.firstBuffer` signpost, once per item (an
    /// `os_signpost` write, built for this).
    ///
    /// - Returns: Whether the whole cycle is silence.
    func render(into output: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard let base = output.baseAddress, !output.isEmpty else { return true }
        let frameCount = output.count
        return state.withLock { state -> Bool in
            var written = 0
            var audible = false

            // 1. The fade-out left by a flush.
            if state.fadeRead < state.fadeCount {
                let count = min(frameCount, state.fadeCount - state.fadeRead)
                state.fade.withUnsafeBufferPointer { fade in
                    (base).update(from: fade.baseAddress! + state.fadeRead, count: count)
                }
                state.fadeRead += count
                written = count
                audible = true
            }

            // 2. Start playing once the jitter buffer is primed.
            if state.mode == .buffering {
                if state.queuedFrames == 0 && !state.awaitingMore {
                    state.mode = .idle
                } else if state.queuedFrames >= state.startThreshold || !state.awaitingMore
                    || state.waitedFrames >= configuration.maximumPrerollWaitFrames
                {
                    state.mode = .playing
                    state.waitedFrames = 0
                } else if state.queuedFrames > 0 {
                    state.waitedFrames += frameCount - written
                }
            }

            // 3. Queued audio.
            if state.mode == .playing {
                written += drain(&state, into: base + written, count: frameCount - written)
                if written > 0 { audible = true }
                if written < frameCount {
                    if state.awaitingMore {
                        // Ran dry while the item is still streaming.
                        state.underrunCount += 1
                        state.mode = .buffering
                        state.startThreshold = configuration.rebufferFrames
                        state.waitedFrames = 0
                    } else {
                        state.mode = .idle
                    }
                }
            }

            // 4. Silence for the rest.
            if written < frameCount {
                (base + written).update(repeating: 0, count: frameCount - written)
            }

            state.renderedFrames += Int64(frameCount)
            if audible {
                var rms: Float = 0
                var peak: Float = 0
                vDSP_rmsqv(base, 1, &rms, vDSP_Length(frameCount))
                vDSP_maxmgv(base, 1, &peak, vDSP_Length(frameCount))
                state.level = PlaybackLevel(rms: rms, peak: peak)
            } else {
                state.level = .silent
            }
            return !audible
        }
    }

    // MARK: Internals

    /// Things to release after the lock is dropped.
    private struct Garbage {
        var chunks: [Chunk] = []
        var interval: SignpostInterval?
        var endedIntervals: [SignpostInterval] = []
    }

    /// Copies up to `count` queued frames to `destination`, crediting each
    /// item. Called with the lock held, from the render thread.
    private func drain(_ state: inout State, into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var copied = 0
        while copied < count && state.readChunk < state.chunks.count {
            let slot = state.chunks[state.readChunk].slot
            let sequence = state.chunks[state.readChunk].sequence
            let available = state.chunks[state.readChunk].samples.count - state.readOffset
            let n = min(available, count - copied)
            let offset = state.readOffset
            state.chunks[state.readChunk].samples.withUnsafeBufferPointer { source in
                (destination + copied).update(from: source.baseAddress! + offset, count: n)
            }
            copied += n
            state.readOffset += n
            state.queuedFrames -= n
            if state.isCurrent(slot: slot, sequence: sequence) {
                state.items[slot].playedFrames += Int64(n)
                state.items[slot].queuedFrames -= n
                if !state.items[slot].hasStartedPlaying {
                    state.items[slot].hasStartedPlaying = true
                    state.items[slot].firstBuffer?.end()
                }
            }
            if state.readOffset == state.chunks[state.readChunk].samples.count {
                state.readChunk += 1
                state.readOffset = 0
            }
        }
        return copied
    }

    /// Copies the next `flushFadeFrames` of queued audio into the fade
    /// buffer with a linear ramp down, and credits them as played.
    private func prepareFade(_ state: inout State) {
        let length = min(configuration.flushFadeFrames, state.queuedFrames)
        guard length > 0 else {
            state.fadeCount = 0
            state.fadeRead = 0
            return
        }
        // Reuse the render path to pull the frames (it credits the items).
        // The buffer is swapped out so `drain` can have the state inout.
        var fade = ContiguousArray<Float>()
        swap(&fade, &state.fade)
        let copied = fade.withUnsafeMutableBufferPointer { fade in
            drain(&state, into: fade.baseAddress!, count: length)
        }
        for index in 0..<copied {
            fade[index] *= Float(copied - index) / Float(copied + 1)
        }
        swap(&fade, &state.fade)
        state.fadeCount = copied
        state.fadeRead = 0
    }

    /// Moves chunks the render thread has finished out of the queue.
    private func reclaimConsumedChunks(_ state: inout State) -> [Chunk] {
        guard state.readChunk > 0 else { return [] }
        let consumed = Array(state.chunks[..<state.readChunk])
        state.chunks.removeFirst(state.readChunk)
        state.readChunk = 0
        return consumed
    }

    /// Assigns `id` the next slot in the ring, recycling the oldest record.
    /// Returns the slot and the recycled record's signpost interval, to be
    /// released outside the lock.
    private func registerItem(_ id: PlaybackItemID, in state: inout State) -> (Int, SignpostInterval?) {
        let sequence = state.nextSequence
        state.nextSequence += 1
        let slot = Int(sequence % UInt64(state.items.count))
        let previous = state.items[slot]
        if let previousID = previous.id, state.slots[previousID] == slot {
            state.slots[previousID] = nil
        }
        state.items[slot] = ItemRecord(
            id: id,
            sequence: sequence,
            firstBuffer: signposter.beginInterval(.playbackFirstBuffer)
        )
        state.slots[id] = slot
        return (slot, previous.firstBuffer)
    }

    private func playedItem(_ record: ItemRecord) -> PlayedItem {
        PlayedItem(
            id: record.id ?? PlaybackItemID(itemID: ""),
            playedFrames: record.playedFrames,
            receivedFrames: record.receivedFrames,
            sampleRate: configuration.sampleRate
        )
    }
}
