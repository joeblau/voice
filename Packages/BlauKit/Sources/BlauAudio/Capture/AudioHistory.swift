/// The most recent `capacity` samples of a stream, addressed by absolute
/// sample offset. Backs `CaptureHub`'s rolling history so voice ID and ASR
/// can look back at audio from before they subscribed or before speech was
/// detected.
///
/// Storage is allocated once. Appending past the capacity overwrites the
/// oldest samples.
struct AudioHistory {
    /// Samples retained.
    let capacity: Int
    private var storage: [Float]
    /// Where the next sample goes in `storage`.
    private var writeIndex = 0
    /// Samples currently retained, at most `capacity`.
    private(set) var count = 0
    /// Offset of the sample right after the newest one retained.
    private(set) var endOffset: Int64

    init(capacity: Int, startOffset: Int64 = 0) {
        precondition(capacity > 0, "History needs room for at least one sample")
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
        self.endOffset = startOffset
    }

    /// Offset of the oldest sample retained.
    var startOffset: Int64 { endOffset - Int64(count) }

    /// The offsets retained.
    var range: Range<Int64> { startOffset..<endOffset }

    /// Appends samples that start at `endOffset`.
    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var source = samples
        if source.count > capacity {
            // Only the newest `capacity` samples survive.
            source = UnsafeBufferPointer(rebasing: source[(source.count - capacity)...])
        }
        storage.withUnsafeMutableBufferPointer { storage in
            let firstCount = min(source.count, capacity - writeIndex)
            (storage.baseAddress! + writeIndex).update(from: source.baseAddress!, count: firstCount)
            if source.count > firstCount {
                storage.baseAddress!.update(from: source.baseAddress! + firstCount, count: source.count - firstCount)
            }
        }
        writeIndex = (writeIndex + source.count) % capacity
        count = min(capacity, count + source.count)
        endOffset += Int64(samples.count)
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Advances past `sampleCount` samples that were lost, keeping offsets
    /// aligned. They read back as silence while they are retained.
    mutating func appendSilence(_ sampleCount: Int64) {
        guard sampleCount > 0 else { return }
        guard sampleCount < Int64(capacity) else {
            // Everything retained would be silence: start over.
            count = 0
            writeIndex = 0
            endOffset += sampleCount
            return
        }
        let silence = [Float](repeating: 0, count: Int(sampleCount))
        append(silence)
    }

    /// The retained samples in `requested`, clipped to what is retained, or
    /// `nil` if none of it is.
    func samples(in requested: Range<Int64>) -> (offset: Int64, samples: [Float])? {
        let lower = max(requested.lowerBound, startOffset)
        let upper = min(requested.upperBound, endOffset)
        guard lower < upper else { return nil }
        let length = Int(upper - lower)
        // Position of `lower` in storage: the oldest retained sample sits at
        // `writeIndex - count` (mod capacity).
        let oldestIndex = (writeIndex - count + capacity) % capacity
        let start = (oldestIndex + Int(lower - startOffset)) % capacity
        var result = [Float](repeating: 0, count: length)
        storage.withUnsafeBufferPointer { storage in
            result.withUnsafeMutableBufferPointer { result in
                let firstCount = min(length, capacity - start)
                result.baseAddress!.update(from: storage.baseAddress! + start, count: firstCount)
                if length > firstCount {
                    (result.baseAddress! + firstCount).update(from: storage.baseAddress!, count: length - firstCount)
                }
            }
        }
        return (lower, result)
    }
}
