import Accelerate
import Foundation

/// Restricts a memory search to some chunks.
public struct MemorySearchFilter: Hashable, Sendable {
    /// Only these kinds; `nil` for every kind.
    public var kinds: Set<MemorySourceKind>?
    /// Only chunks whose `createdAt` falls in this range; `nil` for any
    /// time.
    public var createdAt: Range<Date>?

    public init(kinds: Set<MemorySourceKind>? = nil, createdAt: Range<Date>? = nil) {
        self.kinds = kinds
        self.createdAt = createdAt
    }

    /// No restriction.
    public static let none = MemorySearchFilter()

    var isUnrestricted: Bool { kinds == nil && createdAt == nil }
}

extension MemorySourceKind {
    /// A distinct bit per kind, for filtering without hashing.
    var bit: UInt8 {
        switch self {
        case .conversation: 1
        case .document: 2
        case .collectionItem: 4
        case .fact: 8
        }
    }
}

/// One ranked result of a keyword or vector search over the index.
public struct MemoryIndexHit: Hashable, Sendable {
    public var chunkID: UUID
    /// Higher is better. BM25 (negated SQLite `bm25()`, so positive) for a
    /// keyword search, cosine similarity in `-1...1` for a vector search.
    /// Only comparable within one search.
    public var score: Double

    public init(chunkID: UUID, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

/// Every stored vector of one model version in one contiguous `[Int8]`
/// matrix, searched by brute force with Accelerate.
///
/// Row `i` occupies `codes[i * dimensions ..< (i + 1) * dimensions]`.
/// Rows are added and removed in O(1) (a removed row is replaced by the
/// last one), so the indexer can update it as it writes. A search converts
/// blocks of rows to `Float` (`vDSP_vflt8`) and multiplies them by the
/// query (`vDSP_mmul`): the dot products of int8 codes are exact in
/// `Float`, and the matrix itself stays int8 (12.8 MB for 50k × 256).
///
/// Scores are cosine similarities of the codes, the same as
/// `TextEmbedding.cosineSimilarity(to:)`. Past ~200k rows an HNSW index
/// (USearch) would be the next step (issue #1).
public struct VectorMatrix: Sendable {
    /// The `TextEmbedding.modelVersion` of every row.
    public let modelVersion: String
    /// Width of every row; taken from the first row added when the matrix
    /// was created without one.
    public private(set) var dimensions: Int

    private(set) var codes: [Int8] = []
    private(set) var rowIDs: [Int64] = []
    private(set) var chunkIDs: [UUID] = []
    private(set) var kinds: [UInt8] = []
    private(set) var createdAt: [Double] = []
    /// 1 / ‖codes‖, or 0 for a zero vector (which then scores 0).
    private(set) var inverseNorms: [Float] = []
    private var slots: [Int64: Int] = [:]

    /// Rows converted to `Float` per block during a search: 256 × 256
    /// floats, 256 KB, so a block stays in the L2 cache.
    static let blockRows = 256

    public init(modelVersion: String, dimensions: Int = 0) {
        self.modelVersion = modelVersion
        self.dimensions = dimensions
    }

    /// Number of rows.
    public var count: Int { rowIDs.count }

    public var isEmpty: Bool { rowIDs.isEmpty }

    /// Bytes held by the int8 codes.
    public var codeBytes: Int { codes.count }

    public func contains(rowID: Int64) -> Bool { slots[rowID] != nil }

    /// Reserves room for `rows` rows of `width` codes (the matrix's width
    /// by default).
    public mutating func reserveCapacity(_ rows: Int, width: Int? = nil) {
        codes.reserveCapacity(rows * (width ?? dimensions))
        rowIDs.reserveCapacity(rows)
        chunkIDs.reserveCapacity(rows)
        kinds.reserveCapacity(rows)
        createdAt.reserveCapacity(rows)
        inverseNorms.reserveCapacity(rows)
        slots.reserveCapacity(rows)
    }

    /// Adds a row, or replaces the row with the same `rowID`. Ignores
    /// vectors of the wrong width.
    public mutating func upsert(
        rowID: Int64, chunkID: UUID, kind: MemorySourceKind, createdAt date: Date,
        codes vector: some Collection<Int8>
    ) {
        if dimensions == 0, isEmpty, !vector.isEmpty { dimensions = vector.count }
        guard vector.count == dimensions else { return }
        var squared: Int32 = 0
        for code in vector { squared += Int32(code) * Int32(code) }
        let inverseNorm: Float = squared > 0 ? 1 / Float(squared).squareRoot() : 0
        if let slot = slots[rowID] {
            let start = slot * dimensions
            codes.replaceSubrange(start..<(start + dimensions), with: vector)
            chunkIDs[slot] = chunkID
            kinds[slot] = kind.bit
            createdAt[slot] = date.timeIntervalSince1970
            inverseNorms[slot] = inverseNorm
            return
        }
        slots[rowID] = rowIDs.count
        codes.append(contentsOf: vector)
        rowIDs.append(rowID)
        chunkIDs.append(chunkID)
        kinds.append(kind.bit)
        createdAt.append(date.timeIntervalSince1970)
        inverseNorms.append(inverseNorm)
    }

    /// Updates what filters see for a row, if present, keeping its vector.
    public mutating func updateMetadata(rowID: Int64, chunkID: UUID, kind: MemorySourceKind, createdAt date: Date) {
        guard let slot = slots[rowID] else { return }
        chunkIDs[slot] = chunkID
        kinds[slot] = kind.bit
        createdAt[slot] = date.timeIntervalSince1970
    }

    /// Removes a row, if present, by moving the last row into its place.
    public mutating func remove(rowID: Int64) {
        guard let slot = slots.removeValue(forKey: rowID) else { return }
        let last = rowIDs.count - 1
        if slot != last {
            let lastStart = last * dimensions
            let start = slot * dimensions
            for offset in 0..<dimensions { codes[start + offset] = codes[lastStart + offset] }
            rowIDs[slot] = rowIDs[last]
            chunkIDs[slot] = chunkIDs[last]
            kinds[slot] = kinds[last]
            createdAt[slot] = createdAt[last]
            inverseNorms[slot] = inverseNorms[last]
            slots[rowIDs[slot]] = slot
        }
        codes.removeLast(dimensions)
        rowIDs.removeLast()
        chunkIDs.removeLast()
        kinds.removeLast()
        createdAt.removeLast()
        inverseNorms.removeLast()
    }

    /// The `limit` rows most similar to `query` (cosine of int8 codes) that
    /// pass `filter`, best first; ties keep row order. Empty for a query of
    /// the wrong width or a zero query.
    public func nearest(to query: [Int8], limit: Int, filter: MemorySearchFilter = .none) -> [MemoryIndexHit] {
        guard limit > 0, query.count == dimensions, !isEmpty else { return [] }
        var squared: Int32 = 0
        for code in query { squared += Int32(code) * Int32(code) }
        guard squared > 0 else { return [] }
        let queryInverseNorm = 1 / Float(squared).squareRoot()

        let dots = dotProducts(query)
        let range = filter.createdAt.map { $0.lowerBound.timeIntervalSince1970..<$0.upperBound.timeIntervalSince1970 }
        let allowedKinds = filter.kinds.map { $0.reduce(UInt8(0)) { $0 | $1.bit } } ?? .max
        var top = TopK(capacity: limit)
        for row in 0..<count {
            if kinds[row] & allowedKinds == 0 { continue }
            if let range, !range.contains(createdAt[row]) { continue }
            top.insert(score: dots[row] * inverseNorms[row] * queryInverseNorm, row: row)
        }
        return top.sorted().map { MemoryIndexHit(chunkID: chunkIDs[$0.row], score: Double($0.score)) }
    }

    /// `codes · query` for every row.
    func dotProducts(_ query: [Int8]) -> [Float] {
        let rows = count
        let dimensions = dimensions
        let queryFloats = query.map(Float.init)
        var dots = [Float](repeating: 0, count: rows)
        let blockRows = Self.blockRows
        var block = [Float](repeating: 0, count: blockRows * dimensions)
        codes.withUnsafeBufferPointer { codes in
            dots.withUnsafeMutableBufferPointer { dots in
                block.withUnsafeMutableBufferPointer { block in
                    queryFloats.withUnsafeBufferPointer { query in
                        guard let codes = codes.baseAddress, let dots = dots.baseAddress,
                            let block = block.baseAddress, let query = query.baseAddress
                        else { return }
                        var start = 0
                        while start < rows {
                            let blockCount = min(blockRows, rows - start)
                            vDSP_vflt8(
                                codes + start * dimensions, 1, block, 1, vDSP_Length(blockCount * dimensions))
                            vDSP_mmul(
                                block, 1, query, 1, dots + start, 1, vDSP_Length(blockCount), 1,
                                vDSP_Length(dimensions))
                            start += blockCount
                        }
                    }
                }
            }
        }
        return dots
    }
}

/// The `capacity` highest scores seen, kept in a min-heap.
struct TopK {
    struct Entry {
        var score: Float
        var row: Int

        /// Worse: a lower score, or the same score on a later row.
        func isWorse(than other: Entry) -> Bool {
            score < other.score || (score == other.score && row > other.row)
        }
    }

    let capacity: Int
    private var heap: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        heap.reserveCapacity(self.capacity)
    }

    mutating func insert(score: Float, row: Int) {
        guard capacity > 0, score.isFinite else { return }
        let entry = Entry(score: score, row: row)
        if heap.count < capacity {
            heap.append(entry)
            siftUp(heap.count - 1)
        } else if heap[0].isWorse(than: entry) {
            heap[0] = entry
            siftDown(0)
        }
    }

    /// Best first.
    func sorted() -> [Entry] {
        heap.sorted { $1.isWorse(than: $0) }
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].isWorse(than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var worst = parent
            if left < heap.count, heap[left].isWorse(than: heap[worst]) { worst = left }
            if right < heap.count, heap[right].isWorse(than: heap[worst]) { worst = right }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}
