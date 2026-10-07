import Foundation

/// A text-embedding model's input embedding table, kept outside Core ML and
/// memory-mapped.
///
/// #59 found that a transformer's token-embedding lookup (a gather over a
/// 151k- or 262k-row table) has no Neural Engine kernel, and that with it
/// inside the model Core ML plans *every* operation on the CPU. So
/// `scripts/embeddings/convert_coreml.py` exports the model from
/// `inputs_embeds` onward and writes the table next to it
/// (`<name>.token-embeddings.f16`): raw little-endian float16, `width`
/// values per row, row `i` for token id `i`, any embedding scale already
/// applied. Mapping it means only the pages of tokens actually used become
/// resident, instead of the whole 300 to 400 MB table.
public struct TokenEmbeddingTable: Sendable {
    public enum Failure: Error, Hashable, Sendable {
        /// The file isn't a whole number of `width`-wide float16 rows.
        case malformed(bytes: Int, width: Int)
        /// A token id outside the table.
        case tokenOutOfRange(Int32, vocabularySize: Int)
        /// The destination can't hold `length` rows of `width` values.
        case destinationTooSmall
    }

    public let width: Int
    public let vocabularySize: Int
    private let data: Data

    /// The bytes per row: `width` float16 values.
    public var rowBytes: Int { width * 2 }

    public init(url: URL, width: Int) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, width: width)
    }

    public init(data: Data, width: Int) throws(Failure) {
        guard width > 0, !data.isEmpty, data.count % (width * 2) == 0 else {
            throw .malformed(bytes: data.count, width: width)
        }
        self.data = data
        self.width = width
        vocabularySize = data.count / (width * 2)
    }

    /// The table next to a converted model: `<model name>.token-embeddings.f16`
    /// in the model's directory, if it exists.
    public static func sibling(of modelURL: URL) -> URL? {
        let name = modelURL.deletingPathExtension().lastPathComponent
        let url = modelURL.deletingLastPathComponent().appendingPathComponent("\(name).token-embeddings.f16")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        data.withUnsafeBytes { (table: UnsafeRawBufferPointer) in
            for (row, id) in ids.enumerated() {
                let source = UnsafeRawBufferPointer(rebasing: table[(Int(id) * rowBytes)..<((Int(id) + 1) * rowBytes)])
                UnsafeMutableRawBufferPointer(rebasing: destination[(row * rowBytes)..<((row + 1) * rowBytes)])
                    .copyMemory(from: source)
            }
        }
        let padding = UnsafeMutableRawBufferPointer(rebasing: destination[(ids.count * rowBytes)..<(length * rowBytes)])
        padding.initializeMemory(as: UInt8.self, repeating: 0)
    }
}
