import CoreML
import Foundation

/// Loads an installed model once so the first real use is fast.
///
/// The first load of a Core ML model on a device compiles it for that
/// device's Neural Engine (3–4 s for Parakeet). Core ML caches the result
/// per OS version, so warming up once after install (and again after an OS
/// update) moves that cost to onboarding instead of the first sentence.
public protocol ModelWarmer: Sendable {
    func warmUp(_ descriptor: ModelDescriptor, at directory: URL) async throws
}

/// Warms up models by loading every compiled bundle with Core ML, using the
/// compute units the pipeline will use (so the cached compilation is the
/// one it needs).
public struct CoreMLModelWarmer: ModelWarmer {
    public init() {}

    @concurrent
    public func warmUp(_ descriptor: ModelDescriptor, at directory: URL) async throws {
        for bundle in descriptor.bundles {
            try Task.checkCancellation()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = Self.computeUnits(for: descriptor.id, bundle: bundle).coreML
            _ = try await MLModel.load(contentsOf: directory.appending(path: bundle), configuration: configuration)
        }
    }

    /// Where each bundle runs, matching FluidAudio's own loaders: everything
    /// on the Neural Engine (with CPU fallback, which keeps background
    /// execution allowed), except Parakeet TDT's preprocessor, which
    /// FluidAudio pins to the CPU.
    public static func computeUnits(for id: ModelID, bundle: String) -> ModelComputeUnits {
        switch (id, bundle) {
        case (.parakeetTDTv3, "Preprocessor.mlmodelc"): .cpuOnly
        default: .cpuAndNeuralEngine
        }
    }
}

/// Compute units, without a Core ML dependency in the logic that picks them.
public enum ModelComputeUnits: Hashable, Sendable {
    case cpuOnly
    case cpuAndNeuralEngine

    var coreML: MLComputeUnits {
        switch self {
        case .cpuOnly: .cpuOnly
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        }
    }
}
