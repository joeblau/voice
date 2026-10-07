import Foundation

/// The noise suppressors the evaluation compares (#51), by the id they
/// carry in reports.
public enum NoiseSuppressorKind: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    /// DeepFilterNet3, Core ML (``DeepFilterNet3Suppressor``). Needs the
    /// model directory.
    case deepFilterNet3 = "dfn3"
    /// Apple's `AUSoundIsolation`, standard voice model
    /// (``SoundIsolationSuppressor``).
    case appleVoiceIsolation = "apple-voice-isolation"
    /// Apple's `AUSoundIsolation`, high-quality voice model.
    case appleVoiceIsolationHighQuality = "apple-voice-isolation-hq"

    public var description: String { rawValue }

    /// Parses a comma-separated list such as `dfn3,apple-voice-isolation`.
    public static func list(_ text: String) throws -> [NoiseSuppressorKind] {
        try text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map {
            guard let kind = NoiseSuppressorKind(rawValue: $0) else {
                throw NoiseSuppressionError.incompatibleModel(
                    "Unknown noise suppressor \($0); known: \(allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return kind
        }
    }

    /// Loads what the suppressor needs once and returns a factory for
    /// per-recording instances.
    ///
    /// - Parameters:
    ///   - deepFilterNet3Directory: The DeepFilterNet3 model directory
    ///     (`scripts/fetch-deepfilternet3.sh`); required for `.deepFilterNet3`.
    ///   - computeUnits: Where Core ML runs DeepFilterNet3.
    public func factory(
        deepFilterNet3Directory: URL?, computeUnits: NoiseSuppressionComputeUnits = .cpuAndNeuralEngine
    ) async throws -> NoiseSuppressorFactory {
        switch self {
        case .deepFilterNet3:
            guard let directory = deepFilterNet3Directory else {
                throw NoiseSuppressionError.incompatibleModel(
                    "DeepFilterNet3 needs its model directory (scripts/fetch-deepfilternet3.sh)")
            }
            let model = try await DeepFilterNet3Model.load(directory: directory, computeUnits: computeUnits)
            return { try DeepFilterNet3Suppressor(model: model) }
        case .appleVoiceIsolation:
            return { try SoundIsolationSuppressor(model: .voice) }
        case .appleVoiceIsolationHighQuality:
            return { try SoundIsolationSuppressor(model: .highQualityVoice) }
        }
    }
}
