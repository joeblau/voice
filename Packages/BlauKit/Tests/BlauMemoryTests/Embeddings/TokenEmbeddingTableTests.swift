import BlauMemory
import Foundation
import Testing

#if canImport(CoreML)
    import CoreML
#endif

@Suite("Token embedding table")
struct TokenEmbeddingTableTests {
    /// float16 bit patterns of small whole numbers, little-endian.
    static func half(_ value: Int) -> [UInt8] {
        let bits: UInt16 =
            switch value {
            case 0: 0x0000
            case 1: 0x3C00
            case 2: 0x4000
            case 3: 0x4200
            default: 0x4400  // 4
            }
        return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
    }

    /// 3 rows of width 2: row i = [i, i + 1].
    static let table: Data = Data((0..<3).flatMap { half($0) + half($0 + 1) })

    @Test func copiesRowsAndZeroPads() throws {
        let table = try TokenEmbeddingTable(data: Self.table, width: 2)
        #expect(table.vocabularySize == 3)
        #expect(table.rowBytes == 4)
        var buffer = [UInt8](repeating: 0xFF, count: 4 * 4)
        try buffer.withUnsafeMutableBytes { try table.copyRows([2, 0], length: 4, into: $0) }
        #expect(buffer == Self.half(2) + Self.half(3) + Self.half(0) + Self.half(1) + [UInt8](repeating: 0, count: 8))
    }

    @Test func rejectsBadInput() throws {
        #expect(throws: TokenEmbeddingTable.Failure.malformed(bytes: 5, width: 2)) {
            try TokenEmbeddingTable(data: Data(count: 5), width: 2)
        }
        let table = try TokenEmbeddingTable(data: Self.table, width: 2)
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(throws: TokenEmbeddingTable.Failure.tokenOutOfRange(3, vocabularySize: 3)) {
            try buffer.withUnsafeMutableBytes { try table.copyRows([3], length: 2, into: $0) }
        }
        #expect(throws: TokenEmbeddingTable.Failure.destinationTooSmall) {
            try buffer.withUnsafeMutableBytes { try table.copyRows([0, 1, 2], length: 3, into: $0) }
        }
    }

    @Test func findsTheTableNextToAModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("Qwen3Embedding06B.mlmodelc")
        #expect(TokenEmbeddingTable.sibling(of: model) == nil)
        let table = directory.appendingPathComponent("Qwen3Embedding06B.token-embeddings.f16")
        try Self.table.write(to: table)
        #expect(TokenEmbeddingTable.sibling(of: model)?.lastPathComponent == table.lastPathComponent)

        // An int8 table is found when there is no float16 one.
        try FileManager.default.removeItem(at: table)
        let int8 = directory.appendingPathComponent("Qwen3Embedding06B.token-embeddings.i8")
        try Self.int8Table.write(to: int8)
        #expect(TokenEmbeddingTable.sibling(of: model)?.lastPathComponent == int8.lastPathComponent)
        #expect(TokenEmbeddingTable.Format(fileURL: int8) == .int8)
        #expect(TokenEmbeddingTable.Format(fileURL: table) == .float16)
    }

    /// An int8 row: float32 little-endian scale, then the codes.
    static func int8Row(scale: Float, _ codes: [Int8]) -> [UInt8] {
        withUnsafeBytes(of: scale.bitPattern.littleEndian, Array.init) + codes.map { UInt8(bitPattern: $0) }
    }

    /// 3 rows of width 2, dequantizing to [1, -2], [0, 0] and [3, 4].
    static let int8Table = Data(
        int8Row(scale: 0.5, [2, -4]) + int8Row(scale: 0, [0, 0]) + int8Row(scale: 4.0 / 127, [95, 127]))

    @Test func dequantizesInt8RowsToFloat16() throws {
        let table = try TokenEmbeddingTable(data: Self.int8Table, width: 2, format: .int8)
        #expect(table.vocabularySize == 3)
        #expect(table.rowBytes == 4)
        #expect(table.storedRowBytes == 6)
        var buffer = [UInt8](repeating: 0xFF, count: 3 * 4)
        try buffer.withUnsafeMutableBytes { try table.copyRows([0, 1], length: 3, into: $0) }
        // 1.0 = 0x3C00, -2.0 = 0xC000, 0.0 = 0x0000; then a zeroed padding row.
        #expect(buffer == [0x00, 0x3C, 0x00, 0xC0] + [0, 0, 0, 0] + [0, 0, 0, 0])

        var last = [UInt8](repeating: 0, count: 4)
        try last.withUnsafeMutableBytes { try table.copyRows([2], length: 1, into: $0) }
        let halves = [UInt16(last[0]) | UInt16(last[1]) << 8, UInt16(last[2]) | UInt16(last[3]) << 8]
        // 95 * 4/127 = 2.992 rounds to float16 0x41FC (2.9922); 127 * 4/127 = 4.0 = 0x4400.
        #expect(halves == [0x41FC, 0x4400])

        #expect(throws: TokenEmbeddingTable.Failure.malformed(bytes: 7, width: 2)) {
            try TokenEmbeddingTable(data: Data(count: 7), width: 2, format: .int8)
        }
        #expect(throws: TokenEmbeddingTable.Failure.tokenOutOfRange(3, vocabularySize: 3)) {
            try buffer.withUnsafeMutableBytes { try table.copyRows([3], length: 1, into: $0) }
        }
    }

    #if canImport(CoreML)
        /// The split model contract end to end through Core ML: a tiny model
        /// (`scripts/embeddings/make_coreml_fixture.py`) whose output is the
        /// masked mean of its input rows.
        @Test func coreMLModelReadsInputEmbeddingsFromTheTable() async throws {
            let directory = try #require(Bundle.module.url(forResource: "Fixtures/CoreML", withExtension: nil))
            let url = directory.appendingPathComponent("TinySplitEmbedding.mlpackage")
            let model = CoreMLTokenEmbeddingModel(url: url, computeUnits: .cpuOnly)
            try await model.load()
            #expect(await model.maximumSequenceLength == 8)
            // Rows 1, 2 and 6: [i, i + 0.5, -i, 1].
            let vector = try await model.embed(tokenIDs: [1, 2, 6])
            let expected: [Float] = [3, 3.5, -3, 1]
            #expect(vector.count == 4)
            for (actual, wanted) in zip(vector, expected) {
                #expect(abs(actual - wanted) < 1e-2)
            }
            await #expect(throws: (any Error).self) { try await model.embed(tokenIDs: [42]) }
            await model.unload()
        }

        /// The same model fed from an int8 copy of its table (#60): rows
        /// are dequantized on the way in, so the output matches to within
        /// the quantization step.
        @Test func coreMLModelReadsAnInt8Table() async throws {
            let directory = try #require(Bundle.module.url(forResource: "Fixtures/CoreML", withExtension: nil))
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            // Row i = [i, i + 0.5, -i, 1], quantized per row.
            var rows: [UInt8] = []
            for i in 0..<10 {
                let values: [Float] = [Float(i), Float(i) + 0.5, -Float(i), 1]
                let scale = values.map(abs).max()! / 127
                rows += Self.int8Row(scale: scale, values.map { Int8(($0 / scale).rounded()) })
            }
            let tableURL = copy.appendingPathComponent("TinySplitEmbedding.token-embeddings.i8")
            try Data(rows).write(to: tableURL)

            let model = CoreMLTokenEmbeddingModel(
                url: directory.appendingPathComponent("TinySplitEmbedding.mlpackage"), computeUnits: .cpuOnly,
                tokenEmbeddings: tableURL)
            try await model.load()
            let vector = try await model.embed(tokenIDs: [1, 2, 6])
            for (actual, wanted) in zip(vector, [Float(3), 3.5, -3, 1]) {
                #expect(abs(actual - wanted) < 0.05)
            }
            await model.unload()
        }

        @Test func modelWithoutItsTableFailsToLoad() async throws {
            let directory = try #require(Bundle.module.url(forResource: "Fixtures/CoreML", withExtension: nil))
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            let package = copy.appendingPathComponent("Lonely.mlpackage")
            try FileManager.default.copyItem(
                at: directory.appendingPathComponent("TinySplitEmbedding.mlpackage"), to: package)
            // The specific error, so a broken package can't pass this vacuously.
            await #expect(throws: CoreMLEmbeddingError.missingTokenEmbeddings("inputs_embeds")) {
                try await CoreMLTokenEmbeddingModel(url: package, computeUnits: .cpuOnly).load()
            }
        }
    #endif

    /// Every item `Manifest.json` lists has to be in git, or Core ML refuses
    /// the package on a clean checkout ("Item does not exist for
    /// identifier"). A weightless model's `weights/` directory is empty, so
    /// it needs its `.gitkeep`.
    @Test func fixturePackageContainsEveryManifestItem() throws {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures/CoreML", withExtension: nil))
        let package = directory.appendingPathComponent("TinySplitEmbedding.mlpackage")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: package.appendingPathComponent("Manifest.json")))
        let entries = try #require((manifest as? [String: Any])?["itemInfoEntries"] as? [String: [String: Any]])
        #expect(!entries.isEmpty)
        for (identifier, entry) in entries {
            let path = try #require(entry["path"] as? String, "\(identifier)")
            let item = package.appendingPathComponent("Data").appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: item.path), "\(path) is listed but missing")
        }
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/.gitkeep")
        #expect(FileManager.default.fileExists(atPath: weights.path))
    }
}
