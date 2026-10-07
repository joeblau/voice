import Accelerate
import Foundation

/// A text-embedding model's input embedding table, kept outside Core ML and
/// memory-mapped.
///
/// #59 found that a transformer's token-embedding lookup (a gather over a
/// 151k- or 262k-row table) has no Neural Engine kernel, and that with it
/// inside the model Core ML plans *every* operation on the CPU. So
/// `scripts/embeddings/convert_coreml.py` exports the model from
/// `inputs_embeds` onward and writes the table next to it, any embedding
/// scale already applied, row `i` for token id `i`, in one of two formats:
///
/// - **float16** (`<name>.token-embeddings.f16`): raw little-endian float16,
///   `width` values per row.
/// - **int8** (`<name>.token-embeddings.i8`, #60): per row, a little-endian
///   float32 scale followed by `width` int8 codes (`value ≈ code × scale`).
///   Half the size of float16 (EmbeddingGemma's 262,144 × 768 table: 202 MB
///   instead of 403 MB), which is what keeps the model inside #59's 400 MB
///   download budget. Rows are dequantized to float16 as they are copied.
///
/// Mapping the file means only the pages of tokens actually used become
/// resident, instead of the whole table.
public struct TokenEmbeddingTable: Sendable {
    public enum Failure: Error, Hashable, Sendable {
        /// The file isn't a whole number of rows of `width` values.
        case malformed(bytes: Int, width: Int)
        /// A token id outside the table.
        case tokenOutOfRange(Int32, vocabularySize: Int)
        /// The destination can't hold `length` rows of `width` values.
        case destinationTooSmall
    }

    /// How the rows are stored.
    public enum Format: String, Codable, Hashable, Sendable {
        case float16
        /// A float32 scale and `width` int8 codes per row.
        case int8

        /// The file extension `convert_coreml.py` gives this format.
        public var fileExtension: String {
            switch self {
            case .float16: "f16"
            case .int8: "i8"
            }
        }

        /// The format a table file's extension names (`.i8` is int8, anything
        /// else float16).
        public init(fileURL: URL) {
            self = fileURL.pathExtension == Self.int8.fileExtension ? .int8 : .float16
        }

        func storedRowBytes(width: Int) -> Int {
            switch self {
            case .float16: width * 2
            case .int8: width + 4
            }
        }
    }

    public let width: Int
    public let vocabularySize: Int
    public let format: Format
    private let data: Data

    /// The bytes per row of the float16 output: `width` float16 values.
    public var rowBytes: Int { width * 2 }

    /// The bytes per row in the file.
    public var storedRowBytes: Int { format.storedRowBytes(width: width) }

    /// Maps the table at `url`; its extension picks the format.
    public init(url: URL, width: Int) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, width: width, format: Format(fileURL: url))
    }

    public init(data: Data, width: Int, format: Format = .float16) throws(Failure) {
        let stored = format.storedRowBytes(width: width)
        guard width > 0, !data.isEmpty, data.count % stored == 0 else {
            throw .malformed(bytes: data.count, width: width)
        }
        self.data = data
        self.width = width
        self.format = format
        vocabularySize = data.count / stored
    }

    /// The table next to a converted model, if it exists:
    /// `<model name>.token-embeddings.f16` (preferred) or `.i8` in the
    /// model's directory.
    public static func sibling(of modelURL: URL) -> URL? {
        let name = modelURL.deletingPathExtension().lastPathComponent
        let directory = modelURL.deletingLastPathComponent()
        for format in [Format.float16, .int8] {
            let url = directory.appendingPathComponent("\(name).token-embeddings.\(format.fileExtension)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Writes the rows of `ids` as float16 into `destination`, a buffer of
    /// `length * width` float16 values laid out row after row, and zeroes the
    /// rows after the last id (padding).
    public func copyRows(_ ids: [Int32], length: Int, into destination: UnsafeMutableRawBufferPointer) throws(Failure) {
        guard ids.count <= length, destination.count >= length * rowBytes else { throw .destinationTooSmall }
        for id in ids where id < 0 || Int(id) >= vocabularySize {
            throw .tokenOutOfRange(id, vocabularySize: vocabularySize)
        }
        let rowBytes = rowBytes
        let storedRowBytes = storedRowBytes
        let width = width
        let format = format
        data.withUnsafeBytes { (table: UnsafeRawBufferPointer) in
            var scratch = [Float](repeating: 0, count: format == .int8 ? width : 0)
            for (row, id) in ids.enumerated() {
                let source = UnsafeRawBufferPointer(
                    rebasing: table[(Int(id) * storedRowBytes)..<((Int(id) + 1) * storedRowBytes)])
                let target = UnsafeMutableRawBufferPointer(
                    rebasing: destination[(row * rowBytes)..<((row + 1) * rowBytes)])
                switch format {
                case .float16:
                    target.copyMemory(from: source)
                case .int8:
                    Self.dequantize(row: source, width: width, scratch: &scratch, into: target)
                }
            }
        }
        let padding = UnsafeMutableRawBufferPointer(rebasing: destination[(ids.count * rowBytes)..<(length * rowBytes)])
        padding.initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// One int8 row (float32 scale, then codes) as float16 in `target`.
    private static func dequantize(
        row: UnsafeRawBufferPointer, width: Int, scratch: inout [Float], into target: UnsafeMutableRawBufferPointer
    ) {
        var scale = Float(bitPattern: UInt32(littleEndian: row.loadUnaligned(as: UInt32.self)))
        let codes = UnsafeRawBufferPointer(rebasing: row[4..<(4 + width)])
        scratch.withUnsafeMutableBufferPointer { floats in
            guard let output = floats.baseAddress,
                let input = codes.baseAddress?.assumingMemoryBound(to: Int8.self)
            else { return }
            vDSP_vflt8(input, 1, output, 1, vDSP_Length(width))
            vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(width))
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(output), height: 1, width: vImagePixelCount(width),
                rowBytes: width * MemoryLayout<Float>.size)
            var destination = vImage_Buffer(
                data: target.baseAddress, height: 1, width: vImagePixelCount(width), rowBytes: width * 2)
            vImageConvert_PlanarFtoPlanar16F(&source, &destination, vImage_Flags(kvImageNoFlags))
        }
    }
}
