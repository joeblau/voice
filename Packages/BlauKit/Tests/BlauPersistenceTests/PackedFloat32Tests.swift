import BlauPersistence
import Foundation
import Testing

@Suite("PackedFloat32")
struct PackedFloat32Tests {
    @Test func packsLittleEndianFloat32() {
        #expect(PackedFloat32.pack([1.0]) == Data([0x00, 0x00, 0x80, 0x3F]))
        #expect(PackedFloat32.pack([-2.5, 0]) == Data([0x00, 0x00, 0x20, 0xC0, 0, 0, 0, 0]))
        #expect(PackedFloat32.pack([]) == Data())
    }

    @Test func roundTripsExactly() {
        let values: [Float] = [0, -0, 1, -1, .pi, .leastNonzeroMagnitude, .greatestFiniteMagnitude, .infinity, 1e-20]
        let unpacked = PackedFloat32.unpack(PackedFloat32.pack(values))
        #expect(unpacked?.map(\.bitPattern) == values.map(\.bitPattern))
    }

    @Test func unpacksFromADataSlice() {
        let data = Data([0xFF] + Array(PackedFloat32.pack([3, 4])))
        #expect(PackedFloat32.unpack(data.dropFirst()) == [3, 4])
    }

    @Test func rejectsLengthsThatAreNotWholeFloats() {
        #expect(PackedFloat32.unpack(Data([1, 2, 3])) == nil)
        #expect(PackedFloat32.unpack(Data([1, 2, 3, 4, 5]), dimension: 1) == nil)
    }

    @Test func packsAndSplitsRows() {
        let rows: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let data = PackedFloat32.pack(rows: rows)
        #expect(data.count == 6 * 4)
        #expect(PackedFloat32.unpack(data, dimension: 3) == rows)
        #expect(PackedFloat32.unpack(data, dimension: 2) == [[1, 2], [3, 4], [5, 6]])
        #expect(PackedFloat32.unpack(data, dimension: 4) == nil)
    }
}
