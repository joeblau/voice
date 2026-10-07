import Foundation

/// Packs `Float` vectors into `Data` as little-endian IEEE-754 Float32, the
/// on-disk and CloudKit format of voiceprint embeddings.
///
/// The byte order is fixed so a voiceprint written on one device reads back
/// identically on another.
public enum PackedFloat32 {
    /// Bytes per packed value.
    public static let byteWidth = MemoryLayout<UInt32>.size

    /// Packs `values` into `values.count * 4` bytes.
    public static func pack(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * byteWidth)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpacks `data`. Returns `nil` if its length is not a multiple of four.
    public static func unpack(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: byteWidth) else { return nil }
        var values: [Float] = []
        values.reserveCapacity(data.count / byteWidth)
        var index = data.startIndex
        while index < data.endIndex {
            var bits: UInt32 = 0
            for shift in 0..<byteWidth {
                bits |= UInt32(data[index + shift]) << (8 * shift)
            }
            values.append(Float(bitPattern: bits))
            index += byteWidth
        }
        return values
    }

    /// Packs equal-length vectors back to back.
    ///
    /// - Precondition: every vector has the same length.
    public static func pack(rows: [[Float]]) -> Data {
        precondition(Set(rows.map(\.count)).count <= 1, "Packed rows must all have the same length")
        return pack(rows.flatMap { $0 })
    }

    /// Splits `data` into vectors of `dimension` values. Returns `nil` if the
    /// data is not a whole number of vectors.
    ///
    /// - Precondition: `dimension > 0`.
    public static func unpack(_ data: Data, dimension: Int) -> [[Float]]? {
        precondition(dimension > 0, "Dimension must be positive")
        guard let flat = unpack(data), flat.count.isMultiple(of: dimension) else { return nil }
        return stride(from: 0, to: flat.count, by: dimension).map { Array(flat[$0..<($0 + dimension)]) }
    }
}
