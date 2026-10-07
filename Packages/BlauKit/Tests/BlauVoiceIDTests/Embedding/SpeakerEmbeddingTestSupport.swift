@preconcurrency import AVFoundation
import BlauCore
import BlauVoiceID
import Foundation
import Synchronization

/// A network that records every waveform and returns `vector(waveform)`,
/// so tests can check what the embedder sends and how it combines the
/// results.
final class FakeSpeakerEmbeddingNetwork: SpeakerEmbeddingNetwork {
    let shape: SpeakerEmbeddingNetworkShape
    private let vector: @Sendable ([Float]) throws -> [Float]
    private let recorded = Mutex<[[Float]]>([])

    init(
        shape: SpeakerEmbeddingNetworkShape = .weSpeaker,
        vector: @escaping @Sendable ([Float]) throws -> [Float]
    ) {
        self.shape = shape
        self.vector = vector
    }

    /// Embeds an input as a one-hot-ish vector keyed on its first sample, so
    /// segments that start with the same value get the same direction.
    convenience init(shape: SpeakerEmbeddingNetworkShape = .weSpeaker) {
        self.init(shape: shape) { input in
            Self.direction(Int(input[0].rounded()), dimension: shape.dimension)
        }
    }

    /// The waveforms received so far, one per model run, in order.
    var inputs: [[Float]] { recorded.withLock { $0 } }

    func embed(_ waveform: [Float]) async throws -> [Float] {
        recorded.withLock { $0.append(waveform) }
        return try vector(waveform)
    }

    /// A raw vector pointing along axis `index` (mod `dimension`), with a
    /// length other than 1 so normalization is observable.
    static func direction(_ index: Int, dimension: Int, length: Float = 3) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[((index % dimension) + dimension) % dimension] = length
        return vector
    }
}

/// A segment of `count` samples, all equal to `value`.
func constantSegment(_ value: Float, count: Int, sampleRate: Int = AudioFrame.captureSampleRate) -> AudioFrame {
    AudioFrame(samples: [Float](repeating: value, count: count), sampleRate: sampleRate, sampleOffset: 0)
}

/// The CMU ARCTIC clips in `Fixtures/Speakers` (see the README there).
enum SpeakerFixtures {
    struct Clip: Sendable {
        let speaker: String
        let utterance: String
        let audio: AudioFrame

        var name: String { "\(speaker)_\(utterance)" }
    }

    static var directory: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url.appending(path: "Speakers", directoryHint: .isDirectory)
        }
    }

    /// Every clip, sorted by speaker then utterance.
    static func load() throws -> [Clip] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            return Clip(speaker: String(parts[0]), utterance: String(parts[1]), audio: try readMono(url))
        }
    }

    /// Reads a mono file as Float samples at its own rate.
    static func readMono(_ url: URL) throws -> AudioFrame {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioFrame(samples: samples, sampleRate: Int(file.processingFormat.sampleRate), sampleOffset: 0)
    }
}
