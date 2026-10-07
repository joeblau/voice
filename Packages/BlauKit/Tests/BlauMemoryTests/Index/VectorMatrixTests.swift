import Foundation
import Testing

@testable import BlauMemory

@Suite("Vector matrix")
struct VectorMatrixTests {
    static let version = "test-8d"

    struct Generator {
        var state: UInt64

        mutating func codes(_ count: Int) -> [Int8] {
            (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int8(truncatingIfNeeded: Int((state >> 33) % 255) - 127)
            }
        }
    }

    static func embedding(_ codes: [Int8]) -> TextEmbedding {
        TextEmbedding(codes: codes, scale: 1 / 127, modelVersion: version, tokenCount: 0)
    }

    /// Brute force with `TextEmbedding.cosineSimilarity`, the reference the
    /// matrix must agree with.
    static func reference(_ rows: [(UUID, [Int8])], query: [Int8], limit: Int) -> [UUID] {
        let q = embedding(query)
        return rows.enumerated()
            .map { index, row in (index, row.0, embedding(row.1).cosineSimilarity(to: q) ?? 0) }
            .sorted { ($0.2, -$0.0) > ($1.2, -$1.0) }
            .prefix(limit)
            .map(\.1)
    }

    @Test func nearestMatchesBruteForceCosineAcrossBlocks() {
        // More rows than one Accelerate block, with a 256-d width.
        var generator = Generator(state: 7)
        let rows = (0..<(VectorMatrix.blockRows * 2 + 37)).map { _ in (UUID(), generator.codes(256)) }
        var matrix = VectorMatrix(modelVersion: Self.version)
        for (index, row) in rows.enumerated() {
            matrix.upsert(
                rowID: Int64(index + 1), chunkID: row.0, kind: .conversation, createdAt: .distantPast, codes: row.1)
        }
        #expect(matrix.dimensions == 256)
        #expect(matrix.count == rows.count)
        for _ in 0..<5 {
            let query = generator.codes(256)
            let hits = matrix.nearest(to: query, limit: 10)
            #expect(hits.map(\.chunkID) == Self.reference(rows, query: query, limit: 10))
            let expected = Self.embedding(rows.first { $0.0 == hits[0].chunkID }!.1)
                .cosineSimilarity(to: Self.embedding(query))!
            #expect(abs(hits[0].score - Double(expected)) < 1e-5)
            #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        }
    }

    @Test func aRowIsItsOwnNearestNeighbour() {
        var generator = Generator(state: 11)
        var matrix = VectorMatrix(modelVersion: Self.version, dimensions: 64)
        let rows = (0..<100).map { _ in (UUID(), generator.codes(64)) }
        for (index, row) in rows.enumerated() {
            matrix.upsert(rowID: Int64(index), chunkID: row.0, kind: .fact, createdAt: .distantPast, codes: row.1)
        }
        let hit = matrix.nearest(to: rows[42].1, limit: 1)[0]
        #expect(hit.chunkID == rows[42].0)
        #expect(abs(hit.score - 1) < 1e-5)
    }

    @Test func removingSwapsTheLastRowIntoPlace() {
        var matrix = VectorMatrix(modelVersion: Self.version, dimensions: 2)
        let ids = (0..<4).map { _ in UUID() }
        let vectors: [[Int8]] = [[1, 0], [0, 1], [-1, 0], [0, -1]]
        for index in 0..<4 {
            matrix.upsert(
                rowID: Int64(index), chunkID: ids[index], kind: .document, createdAt: .distantPast,
                codes: vectors[index])
        }
        matrix.remove(rowID: 1)
        matrix.remove(rowID: 99)
        #expect(matrix.count == 3)
        #expect(!matrix.contains(rowID: 1))
        #expect(matrix.contains(rowID: 3))
        #expect(matrix.nearest(to: [0, -1], limit: 1).first?.chunkID == ids[3])
        #expect(matrix.nearest(to: [0, 1], limit: 3).map(\.chunkID).contains(ids[1]) == false)

        // Replacing a row's vector in place.
        matrix.upsert(rowID: 3, chunkID: ids[3], kind: .document, createdAt: .distantPast, codes: [0, 1])
        #expect(matrix.count == 3)
        #expect(matrix.nearest(to: [0, 1], limit: 1).first?.chunkID == ids[3])

        for rowID in [0, 2, 3] { matrix.remove(rowID: Int64(rowID)) }
        #expect(matrix.isEmpty)
        #expect(matrix.codeBytes == 0)
        #expect(matrix.nearest(to: [0, 1], limit: 1).isEmpty)
    }

    @Test func filtersByKindAndTime() {
        var matrix = VectorMatrix(modelVersion: Self.version, dimensions: 2)
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_768_435_200)
        let kinds: [MemorySourceKind] = [.conversation, .document, .fact, .conversation]
        let ids = kinds.map { _ in UUID() }
        for index in 0..<4 {
            matrix.upsert(
                rowID: Int64(index), chunkID: ids[index], kind: kinds[index],
                createdAt: base.addingTimeInterval(Double(index) * day), codes: [100, Int8(index)])
        }
        let all = matrix.nearest(to: [100, 0], limit: 10)
        #expect(all.count == 4)
        let conversations = matrix.nearest(to: [100, 0], limit: 10, filter: MemorySearchFilter(kinds: [.conversation]))
        #expect(Set(conversations.map(\.chunkID)) == [ids[0], ids[3]])
        let window = matrix.nearest(
            to: [100, 0], limit: 10,
            filter: MemorySearchFilter(createdAt: base.addingTimeInterval(day)..<base.addingTimeInterval(3 * day)))
        #expect(Set(window.map(\.chunkID)) == [ids[1], ids[2]])
        #expect(matrix.nearest(to: [100, 0], limit: 10, filter: MemorySearchFilter(kinds: [])).isEmpty)

        matrix.updateMetadata(rowID: 1, chunkID: ids[1], kind: .conversation, createdAt: base)
        let moved = matrix.nearest(to: [100, 0], limit: 10, filter: MemorySearchFilter(kinds: [.conversation]))
        #expect(Set(moved.map(\.chunkID)) == [ids[0], ids[1], ids[3]])
    }

    @Test func zeroAndMismatchedVectorsNeverMatch() {
        var matrix = VectorMatrix(modelVersion: Self.version, dimensions: 2)
        matrix.upsert(rowID: 1, chunkID: UUID(), kind: .fact, createdAt: .distantPast, codes: [0, 0])
        matrix.upsert(rowID: 2, chunkID: UUID(), kind: .fact, createdAt: .distantPast, codes: [1, 2, 3])
        #expect(matrix.count == 1)
        #expect(matrix.nearest(to: [0, 0], limit: 5).isEmpty)
        #expect(matrix.nearest(to: [1, 1, 1], limit: 5).isEmpty)
        #expect(matrix.nearest(to: [1, 1], limit: 5).map(\.score) == [0])
        #expect(matrix.nearest(to: [1, 1], limit: 0).isEmpty)
    }

    @Test func topKKeepsTheBestInOrder() {
        var top = TopK(capacity: 3)
        for (row, score) in [0.1, 0.9, 0.5, 0.9, -1, 0.7, .nan].enumerated() {
            top.insert(score: Float(score), row: row)
        }
        #expect(top.sorted().map(\.row) == [1, 3, 5])
    }
}
