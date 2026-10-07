import Accelerate
import Foundation

/// Turns a stream of little-endian, mono, signed 16-bit PCM bytes into
/// `Float` samples in `-1..<1`.
///
/// The realtime API sends `response.output_audio.delta` as base64 PCM16
/// (or as binary frames). Deltas normally hold whole samples, but nothing
/// guarantees it, so a trailing odd byte is held back and joined with the
/// first byte of the next delta of the same stream.
public struct PCM16Decoder: Sendable, Hashable {
    /// The first byte of a sample whose second byte hasn't arrived yet.
    public private(set) var pendingByte: UInt8?

    public init() {}

    /// Decodes a base64 delta.
    ///
    /// - Throws: `PlaybackError.invalidBase64`.
    public mutating func decode(base64 delta: String) throws(PlaybackError) -> [Float] {
        guard let data = Data(base64Encoded: delta) else { throw .invalidBase64 }
        return decode(data)
    }

    /// Decodes raw PCM16 bytes.
    public mutating func decode(_ bytes: Data) -> [Float] {
        guard !bytes.isEmpty else { return [] }
        var data = bytes
        if let pendingByte {
            data.insert(pendingByte, at: data.startIndex)
            self.pendingByte = nil
        }
        if data.count % 2 == 1 {
            pendingByte = data.removeLast()
        }
        let count = data.count / 2
        guard count > 0 else { return [] }

        var integers = [Int16](repeating: 0, count: count)
        integers.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[..<(count * 2)]))
            }
        }
        if Int16(littleEndian: 1) != 1 {
            // Big-endian host: the wire format is little-endian.
            for index in integers.indices { integers[index] = Int16(littleEndian: integers[index]) }
        }
        return Self.floats(from: integers)
    }

    /// Drops a held-back byte, for example when its stream was flushed.
    public mutating func reset() {
        pendingByte = nil
    }

    /// `Int16` samples scaled to `-1..<1` (divided by 32 768).
    public static func floats(from samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var floats = [Float](repeating: 0, count: samples.count)
        vDSP.convertElements(of: samples, to: &floats)
        vDSP.multiply(1 / 32_768, floats, result: &floats)
        return floats
    }
}
