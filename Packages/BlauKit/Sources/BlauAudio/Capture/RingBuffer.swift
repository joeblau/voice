import Synchronization

// Lock-free single-producer, single-consumer ring buffers for the capture
// path. The producer is the audio I/O thread (an `AVAudioSinkNode` receiver
// block) and the consumer is the capture thread that resamples and fans out.
//
// The producer-side methods are annotated `@_noLocks`, so the compiler
// rejects any change that would make them allocate, lock, retain or release
// objects, touch generic metadata or call code it can't see. That is the
// static half of "no allocations on the audio thread"; `CaptureAllocationTests`
// checks the same at run time.

/// The read and write positions of an SPSC ring of `capacity` slots.
///
/// Both positions count slots ever written or read, so `head - tail` is the
/// fill level and there is no ambiguity between full and empty. `Int` is 64
/// bits, so they don't wrap in any realistic session. The producer publishes
/// with a release store of `head` after filling slots; the consumer
/// publishes with a release store of `tail` after copying slots out. Each
/// side loads the other's position with acquire ordering.
struct RingCursor: ~Copyable, Sendable {
    /// Number of slots. A power of two.
    let capacity: Int
    private let mask: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    /// - Parameter minimumCapacity: Rounded up to a power of two.
    init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0, "A ring buffer needs at least one slot")
        var capacity = 1
        while capacity < minimumCapacity {
            capacity <<= 1
        }
        self.capacity = capacity
        self.mask = capacity - 1
    }

    // MARK: Producer

    /// Free slots. Producer only.
    @_noLocks
    func writableCount() -> Int {
        capacity - (head.load(ordering: .relaxed) - tail.load(ordering: .acquiring))
    }

    /// Storage index of the next slot to write. Producer only.
    @_noLocks
    func writeIndex() -> Int {
        head.load(ordering: .relaxed) & mask
    }

    /// Publishes `count` slots written at `writeIndex()`. Producer only.
    @_noLocks
    func commitWrite(_ count: Int) {
        head.store(head.load(ordering: .relaxed) + count, ordering: .releasing)
    }

    // MARK: Consumer

    /// Filled slots. Consumer only.
    @_noLocks
    func readableCount() -> Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    /// Storage index of the next slot to read. Consumer only.
    @_noLocks
    func readIndex() -> Int {
        tail.load(ordering: .relaxed) & mask
    }

    /// Releases `count` slots read at `readIndex()`. Consumer only.
    @_noLocks
    func commitRead(_ count: Int) {
        tail.store(tail.load(ordering: .relaxed) + count, ordering: .releasing)
    }

    /// Total slots ever written, for diagnostics.
    var totalWritten: Int { head.load(ordering: .acquiring) }
}

// MARK: - Samples

/// Two contiguous pieces of ring storage that together hold a write of
/// `first.count + secondCount` samples. `second` is only valid when
/// `secondCount > 0`.
struct RingWriteRegions {
    let first: UnsafeMutablePointer<Float>
    let firstCount: Int
    let second: UnsafeMutablePointer<Float>
    let secondCount: Int
}

/// An SPSC ring of mono `Float` samples with preallocated storage.
///
/// `@unchecked Sendable`: the storage pointer is shared between exactly one
/// producer thread and one consumer thread. The producer only writes slots
/// in the free region and the consumer only reads slots in the filled
/// region; `RingCursor`'s release/acquire pair orders those accesses, so no
/// slot is ever touched by both threads at once.
struct SampleRingBuffer: ~Copyable, @unchecked Sendable {
    let cursor: RingCursor
    private let storage: UnsafeMutablePointer<Float>

    /// - Parameter minimumCapacity: Samples to hold, rounded up to a power
    ///   of two.
    init(minimumCapacity: Int) {
        cursor = RingCursor(minimumCapacity: minimumCapacity)
        storage = .allocate(capacity: cursor.capacity)
        storage.initialize(repeating: 0, count: cursor.capacity)
    }

    deinit {
        storage.deallocate()
    }

    var capacity: Int { cursor.capacity }

    /// Samples waiting to be read.
    var readableCount: Int { cursor.readableCount() }

    // MARK: Producer

    /// The storage to write `count` samples into, or `nil` if there isn't
    /// room for all of them. Fill both regions, then `commitWrite(count)`.
    @_noLocks
    func writeRegions(count: Int) -> RingWriteRegions? {
        guard count > 0, count <= cursor.writableCount() else { return nil }
        let start = cursor.writeIndex()
        let firstCount = min(count, cursor.capacity - start)
        return RingWriteRegions(
            first: storage + start,
            firstCount: firstCount,
            second: storage,
            secondCount: count - firstCount
        )
    }

    @_noLocks
    func commitWrite(_ count: Int) {
        cursor.commitWrite(count)
    }

    /// Copies all of `source` in, or nothing if it doesn't fit.
    ///
    /// - Returns: Whether the samples were written.
    @_noLocks
    func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        guard let regions = writeRegions(count: count) else { return false }
        // Raw byte copies: `Float` is trivial, and the typed `update(from:)`
        // carries a generic deinitialization path the checker rejects.
        UnsafeMutableRawPointer(regions.first).copyMemory(
            from: source, byteCount: regions.firstCount * MemoryLayout<Float>.stride)
        if regions.secondCount > 0 {
            UnsafeMutableRawPointer(regions.second).copyMemory(
                from: source + regions.firstCount, byteCount: regions.secondCount * MemoryLayout<Float>.stride)
        }
        commitWrite(count)
        return true
    }

    // MARK: Consumer

    /// Copies up to `count` samples out.
    ///
    /// - Returns: The number of samples copied.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let available = min(count, cursor.readableCount())
        guard available > 0 else { return 0 }
        let start = cursor.readIndex()
        let firstCount = min(available, cursor.capacity - start)
        destination.update(from: storage + start, count: firstCount)
        if available > firstCount {
            (destination + firstCount).update(from: storage, count: available - firstCount)
        }
        cursor.commitRead(available)
        return available
    }

    /// Drops up to `count` unread samples.
    ///
    /// - Returns: The number of samples dropped.
    func skip(_ count: Int) -> Int {
        let available = min(count, cursor.readableCount())
        cursor.commitRead(available)
        return available
    }
}

// MARK: - Chunks

/// What the producer knows about one hardware buffer it put in the sample
/// ring. The consumer reads one of these, then exactly `frameCount` samples.
struct CaptureChunk: Hashable, Sendable, BitwiseCopyable {
    /// Mono samples at the hardware rate that follow in the sample ring.
    var frameCount: Int
    /// Host time (`mach_absolute_time` ticks) of the first sample, or `0`
    /// when the hardware didn't provide one.
    var hostTime: UInt64
    /// Hardware frames dropped right before this chunk because the ring was
    /// full.
    var gapFrames: Int
    /// Hardware buffers dropped right before this chunk.
    var droppedBuffers: Int

    // Spelled out so it can carry `@_noLocks`: the producer builds chunks on
    // the audio thread, and the checker only trusts calls into other files
    // that are annotated.
    @_noLocks
    init(frameCount: Int, hostTime: UInt64, gapFrames: Int, droppedBuffers: Int) {
        self.frameCount = frameCount
        self.hostTime = hostTime
        self.gapFrames = gapFrames
        self.droppedBuffers = droppedBuffers
    }
}

/// An SPSC queue of `CaptureChunk` headers with preallocated storage.
///
/// `@unchecked Sendable` for the same reason as `SampleRingBuffer`: one
/// producer, one consumer, ordered by `RingCursor`.
struct CaptureChunkQueue: ~Copyable, @unchecked Sendable {
    let cursor: RingCursor
    private let storage: UnsafeMutablePointer<CaptureChunk>

    init(minimumCapacity: Int) {
        cursor = RingCursor(minimumCapacity: minimumCapacity)
        storage = .allocate(capacity: cursor.capacity)
        storage.initialize(
            repeating: CaptureChunk(frameCount: 0, hostTime: 0, gapFrames: 0, droppedBuffers: 0),
            count: cursor.capacity
        )
    }

    deinit {
        storage.deallocate()
    }

    var capacity: Int { cursor.capacity }

    var count: Int { cursor.readableCount() }

    /// Whether `push` would succeed. Producer only.
    @_noLocks
    func hasSpace() -> Bool {
        cursor.writableCount() > 0
    }

    /// Appends `chunk` if there is room. Producer only.
    @_noLocks
    func push(_ chunk: CaptureChunk) -> Bool {
        guard cursor.writableCount() > 0 else { return false }
        storage[cursor.writeIndex()] = chunk
        cursor.commitWrite(1)
        return true
    }

    /// Removes and returns the oldest chunk. Consumer only.
    func pop() -> CaptureChunk? {
        guard cursor.readableCount() > 0 else { return nil }
        let chunk = storage[cursor.readIndex()]
        cursor.commitRead(1)
        return chunk
    }
}
