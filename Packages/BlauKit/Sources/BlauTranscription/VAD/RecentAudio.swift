/// A fixed-size ring of the most recent samples of a stream, addressed by
/// absolute sample offset. The segmenter uses it to hand a segment's first
/// audio (from the onset up to the decision) to `speechAudio()`
/// subscribers.
struct RecentAudio {
    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0
    /// Offset of the sample after the newest one.
    private(set) var endOffset: Int64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        storage = [Float](repeating: 0, count: capacity)
    }

    var capacity: Int { storage.count }

    /// The offsets currently retained.
    var range: Range<Int64> { (endOffset - Int64(count))..<endOffset }

    /// Empties the ring; the next sample appended is at `offset`.
    mutating func reset(at offset: Int64) {
        writeIndex = 0
        count = 0
        endOffset = offset
    }

    mutating func append(_ samples: ArraySlice<Float>) {
        var remaining = samples[...]
        if remaining.count > storage.count {
            // Only the newest `capacity` samples can be kept.
            endOffset += Int64(remaining.count - storage.count)
            remaining = remaining.suffix(storage.count)
        }
        for sample in remaining {
            storage[writeIndex] = sample
            writeIndex = writeIndex + 1 == storage.count ? 0 : writeIndex + 1
        }
        count = min(count + remaining.count, storage.count)
        endOffset += Int64(remaining.count)
    }

    /// The retained samples in `requested`, clipped to what is retained, or
    /// `nil` if none are.
    func samples(in requested: Range<Int64>) -> (offset: Int64, samples: [Float])? {
        let clipped = requested.clamped(to: range)
        guard !clipped.isEmpty else { return nil }
        let oldestIndex = (writeIndex - count + storage.count) % storage.count
        var result = [Float]()
        result.reserveCapacity(clipped.count)
        var index = (oldestIndex + Int(clipped.lowerBound - range.lowerBound)) % storage.count
        for _ in 0..<clipped.count {
            result.append(storage[index])
            index = index + 1 == storage.count ? 0 : index + 1
        }
        return (clipped.lowerBound, result)
    }
}
