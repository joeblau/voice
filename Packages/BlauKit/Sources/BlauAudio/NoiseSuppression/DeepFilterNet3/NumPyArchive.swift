import Foundation

/// A float32 array read from a NumPy `.npy` entry.
struct NumPyArray: Hashable, Sendable {
    var shape: [Int]
    var values: [Float]
}

/// Reads the float32 arrays of an **uncompressed** NumPy `.npz` archive
/// (`numpy.savez`, not `savez_compressed`): a ZIP file of stored `.npy`
/// entries, with or without ZIP64 extra fields.
///
/// DeepFilterNet3's `auxiliary.npz` (analysis window, ERB filterbanks and
/// the initial normalization state) is written this way. Anything else, a
/// compressed entry or another dtype, is refused rather than misread.
/// Fortran-ordered arrays (the conversion stores `erb_inv_fb`
/// that way) are reordered to row-major.
enum NumPyArchive {
    enum ReadError: Error, Hashable, CustomStringConvertible {
        case malformed(String)
        case unsupported(String)

        var description: String {
            switch self {
            case .malformed(let reason): "Malformed .npz: \(reason)"
            case .unsupported(let reason): "Unsupported .npz: \(reason)"
            }
        }
    }

    static func read(contentsOf url: URL) throws -> [String: NumPyArray] {
        try read(Data(contentsOf: url))
    }

    static func read(_ data: Data) throws(ReadError) -> [String: NumPyArray] {
        let bytes = [UInt8](data)
        var arrays: [String: NumPyArray] = [:]
        var offset = 0
        while offset + 4 <= bytes.count {
            let signature = bytes.uint32(at: offset)
            // Local file headers come first; the central directory ends the
            // entries.
            guard signature == 0x0403_4B50 else {
                guard signature == 0x0201_4B50 || signature == 0x0605_4B50 else {
                    throw .malformed("unexpected record 0x\(String(signature, radix: 16)) at \(offset)")
                }
                break
            }
            guard offset + 30 <= bytes.count else { throw .malformed("truncated local header at \(offset)") }
            let flags = bytes.uint16(at: offset + 6)
            let method = bytes.uint16(at: offset + 8)
            var compressedSize = UInt64(bytes.uint32(at: offset + 18))
            var uncompressedSize = UInt64(bytes.uint32(at: offset + 22))
            let nameLength = Int(bytes.uint16(at: offset + 26))
            let extraLength = Int(bytes.uint16(at: offset + 28))
            let nameStart = offset + 30
            let extraStart = nameStart + nameLength
            let dataStart = extraStart + extraLength
            guard dataStart <= bytes.count else { throw .malformed("truncated entry header at \(offset)") }
            let name = String(decoding: bytes[nameStart..<extraStart], as: UTF8.self)
            guard method == 0 else { throw .unsupported("\(name) is compressed (method \(method))") }
            guard flags & 0x0008 == 0 else { throw .unsupported("\(name) uses a trailing data descriptor") }

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF {
                // ZIP64: the real sizes are in extra field 0x0001, in the
                // order uncompressed, compressed, for those set to all ones.
                var field = extraStart
                var found = false
                while field + 4 <= dataStart {
                    let tag = bytes.uint16(at: field)
                    let size = Int(bytes.uint16(at: field + 2))
                    guard field + 4 + size <= dataStart else { throw .malformed("truncated extra field in \(name)") }
                    if tag == 0x0001 {
                        var cursor = field + 4
                        if uncompressedSize == 0xFFFF_FFFF {
                            guard cursor + 8 <= field + 4 + size else { throw .malformed("short ZIP64 field") }
                            uncompressedSize = bytes.uint64(at: cursor)
                            cursor += 8
                        }
                        if compressedSize == 0xFFFF_FFFF {
                            guard cursor + 8 <= field + 4 + size else { throw .malformed("short ZIP64 field") }
                            compressedSize = bytes.uint64(at: cursor)
                        }
                        found = true
                        break
                    }
                    field += 4 + size
                }
                guard found else { throw .malformed("\(name) has no ZIP64 sizes") }
            }
            guard compressedSize == uncompressedSize, compressedSize <= UInt64(bytes.count - dataStart) else {
                throw .malformed("\(name) has inconsistent sizes")
            }
            let end = dataStart + Int(compressedSize)
            let key = name.hasSuffix(".npy") ? String(name.dropLast(4)) : name
            arrays[key] = try parseNPY(bytes[dataStart..<end], name: name)
            offset = end
        }
        return arrays
    }

    /// Parses one `.npy` payload: magic, version, header dictionary, data.
    static func parseNPY(_ bytes: ArraySlice<UInt8>, name: String) throws(ReadError) -> NumPyArray {
        let base = bytes.startIndex
        guard bytes.count >= 10, bytes[base] == 0x93, Array(bytes[(base + 1)..<(base + 6)]) == Array("NUMPY".utf8)
        else { throw .malformed("\(name) is not a .npy array") }
        let major = bytes[base + 6]
        let headerLength: Int
        let headerStart: Int
        switch major {
        case 1:
            headerLength = Int(UInt16(bytes[base + 8]) | UInt16(bytes[base + 9]) << 8)
            headerStart = base + 10
        case 2, 3:
            guard bytes.count >= 12 else { throw .malformed("\(name) has a truncated header") }
            headerLength = Int(
                UInt32(bytes[base + 8]) | UInt32(bytes[base + 9]) << 8 | UInt32(bytes[base + 10]) << 16
                    | UInt32(bytes[base + 11]) << 24)
            headerStart = base + 12
        default:
            throw .unsupported("\(name) is .npy version \(major)")
        }
        let dataStart = headerStart + headerLength
        guard dataStart <= bytes.endIndex else { throw .malformed("\(name) has a truncated header") }
        let header = String(decoding: bytes[headerStart..<dataStart], as: UTF8.self)

        guard let descr = value(of: "descr", in: header), descr == "'<f4'" else {
            throw .unsupported("\(name) is not little-endian float32 (\(value(of: "descr", in: header) ?? "?"))")
        }
        let fortranOrder: Bool
        switch value(of: "fortran_order", in: header) {
        case "False": fortranOrder = false
        case "True": fortranOrder = true
        default: throw .malformed("\(name) has no fortran_order")
        }
        guard let shapeText = value(of: "shape", in: header) else { throw .malformed("\(name) has no shape") }
        let dimensions = shapeText.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var shape: [Int] = []
        for dimension in dimensions {
            guard let size = Int(dimension), size >= 0 else { throw .malformed("\(name) has shape \(shapeText)") }
            shape.append(size)
        }
        let count = shape.reduce(1, *)
        guard bytes.endIndex - dataStart == count * 4 else {
            throw .malformed("\(name) holds \(bytes.endIndex - dataStart) bytes for shape \(shape)")
        }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            bytes[dataStart...].withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        // `.npy` float32 is little-endian, like every Apple platform.
        if fortranOrder { values = rowMajor(fromColumnMajor: values, shape: shape) }
        return NumPyArray(shape: shape, values: values)
    }

    /// Reorders a column-major (Fortran) array into row-major order: the
    /// first index varies fastest in the input, the last in the output.
    static func rowMajor(fromColumnMajor values: [Float], shape: [Int]) -> [Float] {
        guard shape.count > 1 else { return values }
        var columnStrides = [Int](repeating: 1, count: shape.count)
        for axis in 1..<shape.count { columnStrides[axis] = columnStrides[axis - 1] * shape[axis - 1] }
        var result = [Float](repeating: 0, count: values.count)
        var index = [Int](repeating: 0, count: shape.count)
        for position in 0..<values.count {
            var source = 0
            for axis in 0..<shape.count { source += index[axis] * columnStrides[axis] }
            result[position] = values[source]
            // Advance the row-major multi-index: last axis fastest.
            var axis = shape.count - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
        return result
    }

    /// The text after `'key':` up to the next top-level comma (a tuple's
    /// commas are inside parentheses).
    private static func value(of key: String, in header: String) -> String? {
        guard let keyRange = header.range(of: "'\(key)':") else { return nil }
        var depth = 0
        var result = ""
        for character in header[keyRange.upperBound...] {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 && (character == "," || character == "}") { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

extension [UInt8] {
    fileprivate func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    fileprivate func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    fileprivate func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
