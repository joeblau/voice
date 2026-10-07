import Foundation
import Testing

@testable import BlauAudio

@Suite("NumPy .npz reader")
struct NumPyArchiveTests {
    /// `numpy.savez(row=a, col=numpy.asfortranarray(a * 10), vec=[0.5, -1.25])`
    /// with `a = arange(6).reshape(2, 3)` as float32: stored entries with
    /// ZIP64 extra fields, as DeepFilterNet3's `auxiliary.npz` is written.
    static let archive = """
        UEsDBC0AAAAAAAAAIQBP6QAq//////////8HABQAcm93Lm5weQEAEACYAAAAAAAAAJgAAAAAAAAAk05VTVBZAQB2AHsnZGVzY3In\
        OiAnPGY0JywgJ2ZvcnRyYW5fb3JkZXInOiBGYWxzZSwgJ3NoYXBlJzogKDIsIDMpLCB9ICAgICAgICAgICAgICAgICAgICAgICAg\
        ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAoAAAAAAACAPwAAAEAAAEBAAACAQAAAoEBQSwMELQAAAAAAAAAhAOsA\
        tlz//////////wcAFABjb2wubnB5AQAQAJgAAAAAAAAAmAAAAAAAAACTTlVNUFkBAHYAeydkZXNjcic6ICc8ZjQnLCAnZm9ydHJh\
        bl9vcmRlcic6IFRydWUsICdzaGFwZSc6ICgyLCAzKSwgfSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg\
        ICAgICAgICAgICAgICAgICAgCgAAAAAAAPBBAAAgQQAAIEIAAKBBAABIQlBLAwQtAAAAAAAAACEAJo0eev//////////BwAUAHZl\
        Yy5ucHkBABAAiAAAAAAAAACIAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzogJzxmNCcsICdmb3J0cmFuX29yZGVyJzogRmFsc2Us\
        ICdzaGFwZSc6ICgyLCksIH0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg\
        ICAKAAAAPwAAoL9QSwECLQMtAAAAAAAAACEAT+kAKpgAAACYAAAABwAAAAAAAAAAAAAAgAEAAAAAcm93Lm5weVBLAQItAy0AAAAA\
        AAAAIQDrALZcmAAAAJgAAAAHAAAAAAAAAAAAAACAAdEAAABjb2wubnB5UEsBAi0DLQAAAAAAAAAhACaNHnqIAAAAiAAAAAcAAAAA\
        AAAAAAAAAIABogEAAHZlYy5ucHlQSwUGAAAAAAMAAwCfAAAAYwIAAAAA
        """

    /// `numpy.savez_compressed(x=a)`.
    static let compressed = """
        UEsDBC0AAAAIAAAAIQBP6QAq//////////8FABQAeC5ucHkBABAAmAAAAAAAAABVAAAAAAAAAJvsF+obEMnIUMZQrZ6SWpxcpG6l\
        oG6TZqKuo6Cell9UUpSYF59flJIKEndLzClOBYoXZyQWpAL5GkY6CsaaOgq1CmQDLgYwaLAHEg5ABMQNQLzAAQBQSwECLQMtAAAA\
        CAAAACEAT+kAKlUAAACYAAAABQAAAAAAAAAAAAAAgAEAAAAAeC5ucHlQSwUGAAAAAAEAAQAzAAAAjAAAAAAA
        """

    /// `numpy.savez(x=a.astype(float64))`.
    static let float64 = """
        UEsDBC0AAAAAAAAAIQDwzTtG//////////8FABQAeC5ucHkBABAAsAAAAAAAAACwAAAAAAAAAJNOVU1QWQEAdgB7J2Rlc2NyJzog\
        JzxmOCcsICdmb3J0cmFuX29yZGVyJzogRmFsc2UsICdzaGFwZSc6ICgyLCAzKSwgfSAgICAgICAgICAgICAgICAgICAgICAgICAg\
        ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKAAAAAAAAAAAAAAAAAADwPwAAAAAAAABAAAAAAAAACEAAAAAAAAAQQAAA\
        AAAAABRAUEsBAi0DLQAAAAAAAAAhAPDNO0awAAAAsAAAAAUAAAAAAAAAAAAAAIABAAAAAHgubnB5UEsFBgAAAAABAAEAMwAAAOcA\
        AAAAAA==
        """

    private func data(_ base64: String) throws -> Data {
        try #require(Data(base64Encoded: base64))
    }

    @Test func readsStoredFloat32ArraysWithZip64Sizes() throws {
        let arrays = try NumPyArchive.read(data(Self.archive))
        #expect(Set(arrays.keys) == ["row", "col", "vec"])
        #expect(arrays["row"] == NumPyArray(shape: [2, 3], values: [0, 1, 2, 3, 4, 5]))
        #expect(arrays["vec"] == NumPyArray(shape: [2], values: [0.5, -1.25]))
    }

    @Test func reordersFortranArraysToRowMajor() throws {
        let arrays = try NumPyArchive.read(data(Self.archive))
        #expect(arrays["col"] == NumPyArray(shape: [2, 3], values: [0, 10, 20, 30, 40, 50]))
        // Three dimensions: element (i, j, k) sits at i + 2j + 6k column-major.
        let shape = [2, 3, 4]
        var columnMajor = [Float](repeating: 0, count: 24)
        for i in 0..<2 {
            for j in 0..<3 {
                for k in 0..<4 { columnMajor[i + 2 * j + 6 * k] = Float(100 * i + 10 * j + k) }
            }
        }
        let rowMajor = NumPyArchive.rowMajor(fromColumnMajor: columnMajor, shape: shape)
        #expect(rowMajor[0] == 0 && rowMajor[1] == 1 && rowMajor[4] == 10 && rowMajor[12] == 100 && rowMajor[23] == 123)
    }

    @Test func refusesWhatItCannotReadCorrectly() throws {
        #expect(throws: NumPyArchive.ReadError.unsupported("x.npy is compressed (method 8)")) {
            try NumPyArchive.read(data(Self.compressed))
        }
        #expect(throws: NumPyArchive.ReadError.self) { try NumPyArchive.read(data(Self.float64)) }
        #expect(throws: NumPyArchive.ReadError.self) { try NumPyArchive.read(Data("not a zip".utf8)) }
        // Truncated in the middle of an entry.
        let truncated = try data(Self.archive).prefix(200)
        #expect(throws: NumPyArchive.ReadError.self) { try NumPyArchive.read(Data(truncated)) }
    }

    @Test func parametersCheckEveryArray() throws {
        func arrays(dropping name: String? = nil, unitShape: [Int] = [1, 96]) -> [String: NumPyArray] {
            let p = syntheticDeepFilterNet3Parameters()
            var arrays = [
                "window": NumPyArray(shape: [960], values: p.window),
                "erb_fb": NumPyArray(shape: [481, 32], values: p.erbFilterbank),
                "erb_inv_fb": NumPyArray(shape: [32, 481], values: p.erbInverseFilterbank),
                "mean_norm_state": NumPyArray(shape: [32], values: p.initialMeanNormalization),
                "unit_norm_state": NumPyArray(
                    shape: unitShape, values: Array(p.initialUnitNormalization.prefix(unitShape.reduce(1, *)))),
            ]
            if let name { arrays[name] = nil }
            return arrays
        }
        let parameters = try DeepFilterNet3Parameters(arrays: arrays())
        #expect(parameters == syntheticDeepFilterNet3Parameters())
        #expect(throws: NoiseSuppressionError.incompatibleModel("auxiliary.npz has no erb_fb")) {
            try DeepFilterNet3Parameters(arrays: arrays(dropping: "erb_fb"))
        }
        #expect(throws: NoiseSuppressionError.self) {
            try DeepFilterNet3Parameters(arrays: arrays(unitShape: [1, 48]))
        }
    }
}
