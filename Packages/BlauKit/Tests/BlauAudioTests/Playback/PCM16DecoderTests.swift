import BlauAudio
import Foundation
import Testing

@Suite("PCM16 decoding")
struct PCM16DecoderTests {
    static func bytes(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func decodesLittleEndianSamplesToUnitFloats() {
        var decoder = PCM16Decoder()
        let floats = decoder.decode(Self.bytes([0, 16_384, -16_384, .max, .min]))
        #expect(floats == [0, 0.5, -0.5, Float(Int16.max) / 32_768, -1])
        #expect(decoder.pendingByte == nil)
    }

    @Test func decodesBase64() throws {
        var decoder = PCM16Decoder()
        let base64 = Self.bytes([1_000, -2_000]).base64EncodedString()
        #expect(try decoder.decode(base64: base64) == [1_000 / 32_768, -2_000 / 32_768])
    }

    @Test func rejectsInvalidBase64() {
        var decoder = PCM16Decoder()
        #expect(throws: PlaybackError.invalidBase64) { try decoder.decode(base64: "not base64!") }
    }

    @Test func joinsASampleSplitAcrossDeltas() {
        let whole = Self.bytes([12_345, -321, 7])
        var decoder = PCM16Decoder()
        var floats = decoder.decode(whole.prefix(3))  // one sample and a half
        #expect(floats.count == 1)
        #expect(decoder.pendingByte == whole[2])
        floats += decoder.decode(whole.dropFirst(3).prefix(1))  // completes the second
        floats += decoder.decode(whole.dropFirst(4))
        #expect(floats == PCM16Decoder.floats(from: [12_345, -321, 7]))
        #expect(decoder.pendingByte == nil)
    }

    @Test func aSingleByteIsHeldBack() {
        var decoder = PCM16Decoder()
        #expect(decoder.decode(Data([0x34])).isEmpty)
        #expect(decoder.decode(Data([0x12])) == [Float(0x1234) / 32_768])
    }

    @Test func resetDropsTheHeldByte() {
        var decoder = PCM16Decoder()
        _ = decoder.decode(Data([0x01, 0x02, 0x03]))
        decoder.reset()
        #expect(decoder.pendingByte == nil)
        #expect(decoder.decode(Data([0x00, 0x40])) == [0.5])
    }

    @Test func emptyInputDecodesToNothing() {
        var decoder = PCM16Decoder()
        #expect(decoder.decode(Data()).isEmpty)
        #expect(PCM16Decoder.floats(from: []).isEmpty)
    }
}
