@preconcurrency import AVFAudio
import BlauCore
import Foundation

/// A recording's part in a voice ID evaluation.
public enum VoiceIDRecordingRole: String, Codable, Hashable, Sendable, CaseIterable {
    /// An enrollment clip (3 to 6 s): its speaker becomes a target, and the
    /// voiceprint is built from these.
    case enrollment
    /// Audio that is scored against every target's voiceprint.
    case probe
    /// An impostor cohort embedding for AS-norm, and a source of background
    /// talkers for the babble and overlap conditions. Cohort speakers must
    /// not appear as targets or probes.
    case cohort
}

/// What kind of sound a recording is. Open-ended: unknown values in a
/// manifest decode as themselves.
public struct VoiceIDSourceKind: RawRepresentable, Hashable, Codable, Sendable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A person talking in the room (the owner or someone else).
    public static let person: VoiceIDSourceKind = "person"
    /// Television: news, shows, ads.
    public static let tv: VoiceIDSourceKind = "tv"
    /// A podcast or other talk audio from a speaker.
    public static let podcast: VoiceIDSourceKind = "podcast"
    /// Music with vocals.
    public static let music: VoiceIDSourceKind = "music"
    /// Speech in a language other than the owner's.
    public static let otherLanguage: VoiceIDSourceKind = "other-language"
    /// Two or more talkers at once.
    public static let overlap: VoiceIDSourceKind = "overlap"

    public var description: String { rawValue }

    public static func < (lhs: VoiceIDSourceKind, rhs: VoiceIDSourceKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The JSON file that describes an evaluation set (see docs/voice-id-eval.md
/// for the format and Datasets/voice-id/ for the owner's set).
public struct VoiceIDDatasetManifest: Codable, Hashable, Sendable {
    /// A short name for reports.
    public var name: String
    /// Whose consent or which licence covers every recording. Required: the
    /// harness refuses a manifest without it.
    public var consent: String
    /// Free text: how and where it was recorded.
    public var description: String?
    public var recordings: [Entry]

    public struct Entry: Codable, Hashable, Sendable {
        /// The audio file, relative to the manifest's directory. Any format
        /// Core Audio reads (WAV, CAF, M4A, FLAC); converted to 16 kHz mono.
        public var path: String
        /// Who is speaking (the dominant talker for overlap). Recordings of
        /// one person share an identifier, e.g. `owner`.
        public var speaker: String
        public var role: VoiceIDRecordingRole
        /// Defaults to `person`.
        public var source: VoiceIDSourceKind?
        /// Conditions for the breakdowns, e.g. `room: kitchen`,
        /// `distance: 2m`, `language: es`, `session: 2026-10-01`.
        public var tags: [String: String]?

        public init(
            path: String, speaker: String, role: VoiceIDRecordingRole, source: VoiceIDSourceKind? = nil,
            tags: [String: String]? = nil
        ) {
            self.path = path
            self.speaker = speaker
            self.role = role
            self.source = source
            self.tags = tags
        }
    }

    public init(name: String, consent: String, description: String? = nil, recordings: [Entry]) {
        self.name = name
        self.consent = consent
        self.description = description
        self.recordings = recordings
    }
}

/// Why an evaluation set can't be used.
public enum VoiceIDDatasetError: Error, Hashable, Sendable {
    /// The manifest doesn't say whose consent or which licence covers it.
    case missingConsent
    /// No enrollment recordings, so there is no one to verify.
    case noTargets
    /// No probe recordings.
    case noProbes
    /// These speakers are in the cohort and also enrolled or probed.
    case cohortOverlapsEvaluation([String])
    /// A path is absolute or leaves the manifest's directory.
    case pathOutsideDataset(String)
    /// A file couldn't be read or converted.
    case unreadableAudio(path: String, reason: String)
    /// A file holds no audio (after trimming silence).
    case emptyAudio(String)
    /// Two entries have the same path and role.
    case duplicateRecording(String)
}

/// One recording, loaded as 16 kHz mono.
public struct VoiceIDEvaluationRecording: Sendable, Identifiable {
    /// Unique within the dataset: the manifest path.
    public let id: String
    public let speaker: String
    public let role: VoiceIDRecordingRole
    public let source: VoiceIDSourceKind
    public let tags: [String: String]
    public let audio: AudioFrame

    /// - Precondition: `audio` is at 16 kHz.
    public init(
        id: String, speaker: String, role: VoiceIDRecordingRole, source: VoiceIDSourceKind = .person,
        tags: [String: String] = [:], audio: AudioFrame
    ) {
        precondition(audio.sampleRate == AudioFrame.captureSampleRate, "Recordings must be 16 kHz")
        self.id = id
        self.speaker = speaker
        self.role = role
        self.source = source
        self.tags = tags
        self.audio = audio
    }
}

/// A validated evaluation set: who is enrolled, what is probed and the
/// impostor cohort.
public struct VoiceIDEvaluationDataset: Sendable {
    public let name: String
    public let consent: String
    public let recordings: [VoiceIDEvaluationRecording]

    /// Speakers with enrollment recordings, sorted.
    public let targetSpeakers: [String]

    /// Validates the set: consent is given, someone is enrolled, there are
    /// probes, ids are unique and no cohort speaker is enrolled or probed.
    public init(name: String, consent: String, recordings: [VoiceIDEvaluationRecording]) throws(VoiceIDDatasetError) {
        guard !consent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .missingConsent }
        var seen = Set<String>()
        for recording in recordings {
            let key = "\(recording.role.rawValue):\(recording.id)"
            guard seen.insert(key).inserted else { throw .duplicateRecording(recording.id) }
        }
        let targets = Set(recordings.filter { $0.role == .enrollment }.map(\.speaker))
        guard !targets.isEmpty else { throw .noTargets }
        guard recordings.contains(where: { $0.role == .probe }) else { throw .noProbes }
        let evaluated = Set(recordings.filter { $0.role != .cohort }.map(\.speaker))
        let cohort = Set(recordings.filter { $0.role == .cohort }.map(\.speaker))
        let overlap = cohort.intersection(evaluated)
        guard overlap.isEmpty else { throw .cohortOverlapsEvaluation(overlap.sorted()) }
        self.name = name
        self.consent = consent
        self.recordings = recordings
        self.targetSpeakers = targets.sorted()
    }

    public func recordings(_ role: VoiceIDRecordingRole) -> [VoiceIDEvaluationRecording] {
        recordings.filter { $0.role == role }
    }

    /// Loads the manifest at `url` and every recording it lists.
    ///
    /// - Parameters:
    ///   - url: The manifest JSON. Paths in it are relative to its directory.
    ///   - trimSilence: Trim leading and trailing silence from each
    ///     recording, as the VAD would before the gate sees it.
    public static func load(manifest url: URL, trimSilence: Bool = true) throws -> VoiceIDEvaluationDataset {
        let manifest = try JSONDecoder().decode(VoiceIDDatasetManifest.self, from: Data(contentsOf: url))
        guard !manifest.consent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceIDDatasetError.missingConsent
        }
        let root = url.deletingLastPathComponent().standardizedFileURL
        let recordings = try manifest.recordings.map { entry in
            let file = try resolve(entry.path, in: root)
            var samples = try readMono16k(file, path: entry.path)
            if trimSilence {
                samples = EvaluationDSP.trimSilence(samples, sampleRate: AudioFrame.captureSampleRate)
            }
            guard !samples.isEmpty else { throw VoiceIDDatasetError.emptyAudio(entry.path) }
            return VoiceIDEvaluationRecording(
                id: entry.path, speaker: entry.speaker, role: entry.role, source: entry.source ?? .person,
                tags: entry.tags ?? [:], audio: AudioFrame(samples: samples, sampleOffset: 0))
        }
        return try VoiceIDEvaluationDataset(name: manifest.name, consent: manifest.consent, recordings: recordings)
    }

    /// `path` inside `root`, refusing absolute paths and `..` escapes.
    static func resolve(_ path: String, in root: URL) throws(VoiceIDDatasetError) -> URL {
        guard !path.hasPrefix("/"), !path.isEmpty else { throw .pathOutsideDataset(path) }
        let file = root.appending(path: path).standardizedFileURL
        let rootPath = root.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard file.path(percentEncoded: false).hasPrefix(prefix) else { throw .pathOutsideDataset(path) }
        return file
    }

    /// Reads any Core Audio file as 16 kHz mono Float samples: channels are
    /// averaged, then resampled with `AVAudioConverter`.
    public static func readMono16k(_ url: URL, path: String? = nil) throws -> [Float] {
        let label = path ?? url.lastPathComponent
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard file.length > 0 else { return [] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
            else { throw VoiceIDDatasetError.unreadableAudio(path: label, reason: "Can't allocate a buffer") }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else {
                throw VoiceIDDatasetError.unreadableAudio(path: label, reason: "Not Float32 PCM")
            }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                for index in 0..<frames { mono[index] += channels[channel][index] }
            }
            if channelCount > 1 {
                mono = mono.map { $0 / Float(channelCount) }
            }
            return try resample(mono, from: format.sampleRate, label: label)
        } catch let error as VoiceIDDatasetError {
            throw error
        } catch {
            throw VoiceIDDatasetError.unreadableAudio(path: label, reason: error.localizedDescription)
        }
    }

    private static func resample(_ samples: [Float], from sampleRate: Double, label: String) throws -> [Float] {
        let target = Double(AudioFrame.captureSampleRate)
        guard sampleRate != target, !samples.isEmpty else { return samples }
        let chunk = 16_384
        guard
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output),
            let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
            let destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(chunk))
        else { throw VoiceIDDatasetError.unreadableAudio(path: label, reason: "No converter from \(sampleRate) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            source.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        // Hand over the whole file once, then signal the end of the stream so
        // the converter drains its filter.
        var supplied = false
        var result: [Float] = []
        result.reserveCapacity(Int(Double(samples.count) * target / sampleRate) + chunk)
        while true {
            destination.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: destination, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if destination.frameLength > 0, let channel = destination.floatChannelData?[0] {
                result += UnsafeBufferPointer(start: channel, count: Int(destination.frameLength))
            }
            switch status {
            case .haveData:
                continue
            case .error:
                throw VoiceIDDatasetError.unreadableAudio(
                    path: label, reason: conversionError?.localizedDescription ?? "Conversion failed")
            default:
                return result
            }
        }
    }
}
