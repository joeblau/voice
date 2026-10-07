import Foundation

/// The `BPE` model of a `tokenizer.json`: splits one pre-tokenized piece into
/// characters and applies the learned merges, lowest rank first, exactly as
/// `tokenizers`' `Word::merge_all` does.
struct BytePairEncoding: Sendable {
    /// What a merge of two adjacent symbols produces.
    struct Merge: Sendable {
        var rank: Int32
        var id: Int32
    }

    /// Keyed by exact Unicode scalars: Swift `String` equality treats
    /// canonically equivalent strings ("é" and "e\u{301}", "Å" and the
    /// Ångström sign) as equal, but they are different tokens.
    let vocabulary: [TokenKey: Int32]
    /// Merges keyed by the two symbol IDs (`left << 32 | right`).
    let merges: [UInt64: Merge]
    let unknownID: Int32?
    let fusesUnknown: Bool
    /// `<0x00>` ... `<0xFF>` when the model falls back to bytes for
    /// characters outside its vocabulary.
    let byteFallback: [Int32]?
    /// Whether a piece that is a whole vocabulary entry skips the merges.
    let ignoresMerges: Bool
    let vocabularySize: Int

    init(json: TokenizerJSON) throws(HuggingFaceTokenizer.Failure) {
        guard json["type"]?.string == "BPE" else {
            throw .unsupported("model \(json["type"]?.string ?? "?") (only BPE)")
        }
        if let dropout = json["dropout"]?.double, dropout > 0 { throw .unsupported("BPE dropout") }
        for key in ["continuing_subword_prefix", "end_of_word_suffix"] {
            if let affix = json[key]?.string, !affix.isEmpty { throw .unsupported("BPE \(key)") }
        }
        guard let rawVocabulary = json["vocab"]?.members else { throw .malformed("BPE without vocab") }
        var vocabulary: [TokenKey: Int32] = [:]
        vocabulary.reserveCapacity(rawVocabulary.count)
        var largest: Int32 = -1
        for (token, value) in rawVocabulary {
            guard let id = value.int32 else { throw .malformed("vocab entry \(token)") }
            vocabulary[TokenKey(token)] = id
            largest = max(largest, id)
        }

        guard let rawMerges = json["merges"]?.array else { throw .malformed("BPE without merges") }
        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(rawMerges.count)
        for (rank, entry) in rawMerges.enumerated() {
            let pair: (String, String)
            if let parts = entry.array, parts.count == 2, let left = parts[0].string, let right = parts[1].string {
                pair = (left, right)
            } else if let line = entry.string, let space = line.unicodeScalars.firstIndex(of: " ") {
                // The older format: "left right".
                let scalars = line.unicodeScalars
                pair = (String(scalars[..<space]), String(scalars[scalars.index(after: space)...]))
            } else {
                throw .malformed("merge \(rank)")
            }
            guard let left = vocabulary[TokenKey(pair.0)], let right = vocabulary[TokenKey(pair.1)],
                let merged = vocabulary[TokenKey(pair.0 + pair.1)]
            else { throw .malformed("merge \(rank) uses a token outside the vocabulary") }
            let key = Self.key(left, right)
            // tokenizers keeps the first (lowest-rank) occurrence of a pair.
            if merges[key] == nil {
                merges[key] = Merge(rank: Int32(rank), id: merged)
            }
        }

        if let unknown = json["unk_token"]?.string {
            guard let id = vocabulary[TokenKey(unknown)] else {
                throw .malformed("unk_token \(unknown) is not in the vocab")
            }
            unknownID = id
        } else {
            unknownID = nil
        }
        if json["byte_fallback"]?.bool == true {
            let bytes = (0..<256).map { vocabulary[TokenKey(String(format: "<0x%02X>", $0))] }
            byteFallback = bytes.allSatisfy { $0 != nil } ? bytes.compactMap { $0 } : nil
        } else {
            byteFallback = nil
        }
        self.vocabulary = vocabulary
        self.merges = merges
        self.fusesUnknown = json["fuse_unk"]?.bool ?? false
        self.ignoresMerges = json["ignore_merges"]?.bool ?? false
        self.vocabularySize = Int(largest) + 1
    }

    static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }

    /// The token IDs of one pre-tokenized piece.
    func encode(_ piece: String) -> [Int32] {
        if ignoresMerges, let id = vocabulary[TokenKey(piece)] { return [id] }

        // One symbol per character (Unicode scalar, like Rust's `char`), or
        // per byte for characters the vocabulary lacks.
        var symbols: [Int32] = []
        symbols.reserveCapacity(piece.unicodeScalars.count)
        var previousWasUnknown = false
        for scalar in piece.unicodeScalars {
            if let id = vocabulary[TokenKey(scalar)] {
                symbols.append(id)
                previousWasUnknown = false
            } else if let bytes = byteFallback {
                for byte in String(scalar).utf8 {
                    symbols.append(bytes[Int(byte)])
                }
                previousWasUnknown = false
            } else if let unknownID {
                if !(fusesUnknown && previousWasUnknown) {
                    symbols.append(unknownID)
                }
                previousWasUnknown = true
            }
            // With no unknown token, tokenizers drops the character.
        }
        guard symbols.count > 1, !merges.isEmpty else { return symbols }
        return Self.applyMerges(to: symbols, merges: merges)
    }

    /// `Word::merge_all`: a priority queue of candidate merges ordered by
    /// rank, then position; stale entries are skipped when popped.
    static func applyMerges(to initial: [Int32], merges: [UInt64: Merge]) -> [Int32] {
        var ids = initial
        let count = ids.count
        var previous = Array(-1..<(count - 1))
        var next = Array(1...count)
        var alive = [Bool](repeating: true, count: count)

        var queue = MergeQueue()
        for position in 0..<(count - 1) {
            if let merge = merges[key(ids[position], ids[position + 1])] {
                queue.push(.init(rank: merge.rank, position: Int32(position), id: merge.id))
            }
        }

        while let top = queue.pop() {
            let position = Int(top.position)
            guard alive[position] else { continue }
            let right = next[position]
            guard right < count else { continue }
            // The pair at this position may have changed since it was queued.
            guard let merge = merges[key(ids[position], ids[right])], merge.id == top.id else { continue }

            ids[position] = top.id
            alive[right] = false
            next[position] = next[right]
            if next[right] < count { previous[next[right]] = position }

            let before = previous[position]
            if before >= 0, let merge = merges[key(ids[before], ids[position])] {
                queue.push(.init(rank: merge.rank, position: Int32(before), id: merge.id))
            }
            let after = next[position]
            if after < count, let merge = merges[key(ids[position], ids[after])] {
                queue.push(.init(rank: merge.rank, position: Int32(position), id: merge.id))
            }
        }

        var result: [Int32] = []
        result.reserveCapacity(count)
        var position = 0
        while position < count {
            result.append(ids[position])
            position = next[position]
        }
        return result
    }
}

/// A binary min-heap of candidate merges by (rank, position).
private struct MergeQueue {
    struct Entry {
        var rank: Int32
        var position: Int32
        var id: Int32

        func precedes(_ other: Entry) -> Bool {
            rank != other.rank ? rank < other.rank : position < other.position
        }
    }

    private var heap: [Entry] = []

    mutating func push(_ entry: Entry) {
        heap.append(entry)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].precedes(heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var best = parent
                if left < heap.count && heap[left].precedes(heap[best]) { best = left }
                if right < heap.count && heap[right].precedes(heap[best]) { best = right }
                guard best != parent else { break }
                heap.swapAt(parent, best)
                parent = best
            }
        }
        return first
    }
}

/// A token's text compared scalar by scalar (by UTF-8 bytes), unlike
/// `String`, which compares by canonical equivalence.
struct TokenKey: Hashable, Sendable {
    let text: String

    init(_ text: String) {
        var text = text
        text.makeContiguousUTF8()
        self.text = text
    }

    init(_ scalar: Unicode.Scalar) {
        self.init(String(scalar))
    }

    static func == (lhs: TokenKey, rhs: TokenKey) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var text = text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
