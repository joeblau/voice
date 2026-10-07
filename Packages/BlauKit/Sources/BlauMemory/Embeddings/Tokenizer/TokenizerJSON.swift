import Foundation

/// A JSON value read byte for byte, for `tokenizer.json`.
///
/// Neither Foundation parser can read a tokenizer's vocabulary faithfully:
/// `JSONSerialization` drops a leading U+FEFF from strings (Gemma has
/// tokens made of byte-order marks), and decoding an object into a Swift
/// `Dictionary` merges keys that are canonically equivalent (Gemma has both
/// "য়" U+09DF and "য়" U+09AF U+09BC, which are different tokens). This
/// parser keeps every string's scalars exactly and every object's members in
/// order, duplicates included.
indirect enum TokenizerJSON: Sendable {
    case object([(key: String, value: TokenizerJSON)])
    case array([TokenizerJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    struct SyntaxError: Error, CustomStringConvertible {
        var offset: Int
        var reason: String

        var description: String { "JSON syntax error at byte \(offset): \(reason)" }
    }

    static func parse(_ data: Data) throws -> TokenizerJSON {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            let value = try parser.value()
            parser.skipWhitespace()
            guard parser.position == parser.bytes.count else { throw parser.error("trailing content") }
            return value
        }
    }

    // MARK: Accessors

    /// The first member named `key` of an object.
    subscript(key: String) -> TokenizerJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var members: [(key: String, value: TokenizerJSON)]? {
        if case .object(let members) = self { members } else { nil }
    }

    var array: [TokenizerJSON]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    var double: Double? {
        if case .number(let number) = self { number } else { nil }
    }

    /// A whole number that fits in `Int32`.
    var int32: Int32? {
        guard case .number(let number) = self, number == number.rounded(),
            number >= Double(Int32.min), number <= Double(Int32.max)
        else { return nil }
        return Int32(number)
    }

    var isNull: Bool {
        if case .null = self { true } else { false }
    }

    // MARK: Parsing

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        func error(_ reason: String) -> SyntaxError {
            SyntaxError(offset: position, reason: reason)
        }

        mutating func skipWhitespace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        mutating func value() throws -> TokenizerJSON {
            skipWhitespace()
            guard position < bytes.count else { throw error("unexpected end") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: StaticString) throws {
            let length = word.utf8CodeUnitCount
            guard position + length <= bytes.count else { throw error("unexpected end") }
            for index in 0..<length where bytes[position + index] != word.utf8Start[index] {
                throw error("expected \(word)")
            }
            position += length
        }

        mutating func object() throws -> TokenizerJSON {
            position += 1
            var members: [(key: String, value: TokenizerJSON)] = []
            skipWhitespace()
            if position < bytes.count && bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                    throw error("expected a key")
                }
                let key = try string()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected :") }
                position += 1
                members.append((key, try value()))
                skipWhitespace()
                guard position < bytes.count else { throw error("unexpected end") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "}") {
                    position += 1
                    return .object(members)
                } else {
                    throw error("expected , or }")
                }
            }
        }

        mutating func array() throws -> TokenizerJSON {
            position += 1
            var elements: [TokenizerJSON] = []
            skipWhitespace()
            if position < bytes.count && bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(elements)
            }
            while true {
                elements.append(try value())
                skipWhitespace()
                guard position < bytes.count else { throw error("unexpected end") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "]") {
                    position += 1
                    return .array(elements)
                } else {
                    throw error("expected , or ]")
                }
            }
        }

        mutating func string() throws -> String {
            position += 1  // opening quote
            let start = position
            // Fast path: no escapes.
            while position < bytes.count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
                    position += 1
                    return text
                }
                if byte == UInt8(ascii: "\\") { break }
                position += 1
            }
            // Slow path: decode escapes into UTF-8.
            var utf8 = Array(bytes[start..<position])
            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case UInt8(ascii: "\""):
                    position += 1
                    return String(decoding: utf8, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    position += 1
                    guard position < bytes.count else { throw error("unexpected end") }
                    let escape = bytes[position]
                    position += 1
                    switch escape {
                    case UInt8(ascii: "\""): utf8.append(0x22)
                    case UInt8(ascii: "\\"): utf8.append(0x5C)
                    case UInt8(ascii: "/"): utf8.append(0x2F)
                    case UInt8(ascii: "b"): utf8.append(0x08)
                    case UInt8(ascii: "f"): utf8.append(0x0C)
                    case UInt8(ascii: "n"): utf8.append(0x0A)
                    case UInt8(ascii: "r"): utf8.append(0x0D)
                    case UInt8(ascii: "t"): utf8.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = UInt32(try hex4())
                        if (0xD800..<0xDC00).contains(scalar) {
                            // A surrogate pair: 😀.
                            guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                                bytes[position + 1] == UInt8(ascii: "u")
                            else { throw error("unpaired surrogate") }
                            position += 2
                            let low = UInt32(try hex4())
                            guard (0xDC00..<0xE000).contains(low) else { throw error("bad low surrogate") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw error("invalid scalar") }
                        utf8 += Array(String(unicode).utf8)
                    default:
                        throw error("bad escape")
                    }
                default:
                    utf8.append(byte)
                    position += 1
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt16 {
            guard position + 4 <= bytes.count else { throw error("unexpected end") }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[position]
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw error("bad \\u escape")
                }
                value = value << 4 | UInt16(digit)
                position += 1
            }
            return value
        }

        mutating func number() throws -> Double {
            let start = position
            while position < bytes.count, Self.isNumberByte(bytes[position]) {
                position += 1
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
            guard !text.isEmpty, let number = Double(text) else { throw error("bad value") }
            return number
        }

        static func isNumberByte(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."),
                UInt8(ascii: "e"), UInt8(ascii: "E"):
                true
            default: false
            }
        }
    }
}
