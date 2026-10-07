@preconcurrency import CoreML
import Foundation
import Testing

@testable import BlauVoiceID

/// The parts of the Core ML network that don't need the model: reading the
/// output tensor. Loading and running the real model is covered by the
/// opt-in `SpeakerEmbeddingModelTests`.
@Suite("CoreMLSpeakerEmbeddingNetwork")
struct CoreMLSpeakerEmbeddingNetworkTests {
    @Test func readsRowsOfAContiguousFloat32Array() throws {
        let array = try MLMultiArray(shape: [3, 4], dataType: .float32)
        for index in 0..<12 {
            array[index] = NSNumber(value: Float(index))
        }
        let rows = try CoreMLSpeakerEmbeddingNetwork.rows(of: array, count: 2, dimension: 4)
        #expect(rows == [[0, 1, 2, 3], [4, 5, 6, 7]])
    }

    @Test func honorsPaddedRowStrides() throws {
        // A [3, 4] array whose rows are 8 floats apart, as the Neural Engine
        // can return.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 24)
        storage.initialize(repeating: -1, count: 24)
        for row in 0..<3 {
            for column in 0..<4 {
                storage[row * 8 + column] = Float(row * 10 + column)
            }
        }
        let array = try MLMultiArray(
            dataPointer: storage, shape: [3, 4], dataType: .float32, strides: [8, 1],
            deallocator: { $0.deallocate() })
        let rows = try CoreMLSpeakerEmbeddingNetwork.rows(of: array, count: 3, dimension: 4)
        #expect(rows == [[0, 1, 2, 3], [10, 11, 12, 13], [20, 21, 22, 23]])
    }

    @Test func convertsFloat16AndDoubleOutputs() throws {
        for dataType in [MLMultiArrayDataType.float16, .double] {
            let array = try MLMultiArray(shape: [2, 2], dataType: dataType)
            for index in 0..<4 {
                array[index] = NSNumber(value: Double(index) + 0.5)
            }
            let rows = try CoreMLSpeakerEmbeddingNetwork.rows(of: array, count: 2, dimension: 2)
            #expect(rows == [[0.5, 1.5], [2.5, 3.5]], "\(dataType.rawValue)")
        }
    }

    @Test func rejectsOutputsOfTheWrongShape() throws {
        let array = try MLMultiArray(shape: [3, 4], dataType: .float32)
        #expect(throws: SpeakerEmbedderError.invalidOutput) {
            try CoreMLSpeakerEmbeddingNetwork.rows(of: array, count: 1, dimension: 256)
        }
        #expect(throws: SpeakerEmbedderError.invalidOutput) {
            try CoreMLSpeakerEmbeddingNetwork.rows(of: array, count: 4, dimension: 4)
        }
        let flat = try MLMultiArray(shape: [12], dataType: .float32)
        #expect(throws: SpeakerEmbedderError.invalidOutput) {
            try CoreMLSpeakerEmbeddingNetwork.rows(of: flat, count: 1, dimension: 12)
        }
    }

    @Test func computeUnitsMapToCoreML() {
        #expect(SpeakerEmbeddingComputeUnits.cpuOnly.coreML == .cpuOnly)
        #expect(SpeakerEmbeddingComputeUnits.cpuAndGPU.coreML == .cpuAndGPU)
        #expect(SpeakerEmbeddingComputeUnits.cpuAndNeuralEngine.coreML == .cpuAndNeuralEngine)
        #expect(SpeakerEmbeddingComputeUnits.all.coreML == .all)
    }

    @Test func loadingAMissingModelFails() async {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).mlmodelc")
        await #expect(throws: (any Error).self) {
            _ = try await CoreMLSpeakerEmbeddingNetwork.load(contentsOf: missing)
        }
    }
}
