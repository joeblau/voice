import BlauAudio
import BlauCore
import Foundation

/// The JSON file that describes an ASR evaluation set: the bundled
/// synthetic fixtures (`Fixtures/ASR/manifest.json`, made by
/// `scripts/make-asr-fixtures.py`) or the owner's recordings
/// (`Datasets/asr/`). The format is in docs/asr-eval.md.
public struct ASREvaluationManifest: Codable, Hashable, Sendable {
    /// A short name for reports.
    public var name: String
    /// Whose consent or which licence covers every recording. Required.
    public var consent: String
    public var description: String?
    /// The sample rate the utterance positions are counted in. Defaults to
    /// 16 kHz; positions at another rate are converted, so labels made on a
    /// 48 kHz recording can stay as they are.
    public var sampleRate: Int?
    public var fixtures: [Entry]

    public struct Entry: Codable, Hashable, Sendable {
        /// Unique within the set, e.g. `cafe-03`.
        public var id: String
        /// The audio file, relative to the manifest's directory: any format
        /// Core Audio reads, converted to 16 kHz mono.
        public var path: String
        /// What the fixture tests, for the per-category breakdown: `clean`,
        /// `cafe`, `tv`, `accented`, `own-voice`... Open-ended.
        public var category: String
        public var description: String?
        /// The file's length in `sampleRate` samples, when known; checked
        /// against the audio so a regenerated file can't drift from its
        /// labels.
        public var sampleCount: Int64?
        /// What is said, in order: one entry per utterance (a stretch of
        /// speech followed by a pause long enough to end a turn).
        public var utterances: [Utterance]
        /// Free-form conditions for reports, e.g. `voice`, `snr`, `accent`.
        public var tags: [String: String]?

        public init(
            id: String, path: String, category: String, description: String? = nil, sampleCount: Int64? = nil,
            utterances: [Utterance], tags: [String: String]? = nil
        ) {
            self.id = id
            self.path = path
            self.category = category
            self.description = description
            self.sampleCount = sampleCount
            self.utterances = utterances
            self.tags = tags
        }
    }

    /// One utterance: where its speech starts and ends, and the words.
    public struct Utterance: Codable, Hashable, Sendable {
        /// First sample of speech (inclusive).
        public var start: Int64
        /// End of speech (exclusive).
        public var end: Int64
        /// The reference transcript, written as spoken (numbers in words).
        public var text: String

        public init(start: Int64, end: Int64, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public init(
        name: String, consent: String, description: String? = nil, sampleRate: Int? = nil, fixtures: [Entry]
    ) {
        self.name = name
        self.consent = consent
        self.description = description
        self.sampleRate = sampleRate
        self.fixtures = fixtures
    }
}

/// Why an evaluation set can't be used.
public enum ASREvaluationDatasetError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The manifest doesn't say whose consent or which licence covers it.
    case missingConsent
    /// The manifest lists no fixtures (or none in the selected categories).
    case noFixtures
    /// Two fixtures share an id.
    case duplicateFixture(String)
    /// A path is absolute or leaves the manifest's directory.
    case pathOutsideDataset(String)
    /// The file is a Git LFS pointer: the audio was never fetched.
    case lfsPointer(String)
    /// A file couldn't be read or converted.
    case unreadableAudio(path: String, reason: String)
    /// The audio's length differs from the manifest's `sampleCount`.
    case lengthMismatch(path: String, expected: Int64, actual: Int64)
    /// An utterance label is empty, out of order, overlapping or outside
    /// the audio.
    case invalidUtterance(fixture: String, reason: String)

    public var description: String {
        switch self {
        case .missingConsent: "The manifest has no consent statement"
        case .noFixtures: "The manifest lists no fixtures"
        case .duplicateFixture(let id): "Two fixtures are called \(id)"
        case .pathOutsideDataset(let path): "\(path) is outside the dataset directory"
        case .lfsPointer(let path):
            "\(path) is a Git LFS pointer, not audio: run `git lfs install && git lfs pull`"
        case .unreadableAudio(let path, let reason): "Can't read \(path): \(reason)"
        case .lengthMismatch(let path, let expected, let actual):
            "\(path) has \(actual) samples, the manifest says \(expected): regenerate the manifest with the audio"
        case .invalidUtterance(let fixture, let reason): "\(fixture): \(reason)"
        }
    }
}

/// One utterance of a fixture, on the 16 kHz timeline of its audio.
public struct ASRReferenceUtterance: Hashable, Sendable {
    /// Where the speech is, in 16 kHz samples from the start of the file.
    public let range: Range<Int64>
    public let text: String

    public init(range: Range<Int64>, text: String) {
        self.range = range
        self.text = text
    }
}

/// A fixture loaded for evaluation: 16 kHz mono audio and what is said in
/// it.
public struct ASREvaluationFixture: Sendable, Identifiable {
    public let id: String
    public let category: String
    public let description: String?
    public let tags: [String: String]
    /// 16 kHz mono samples.
    public let samples: [Float]
    /// The utterances, in order, without overlaps.
    public let utterances: [ASRReferenceUtterance]

    public init(
        id: String, category: String, description: String? = nil, tags: [String: String] = [:], samples: [Float],
        utterances: [ASRReferenceUtterance]
    ) {
        self.id = id
        self.category = category
        self.description = description
        self.tags = tags
        self.samples = samples
        self.utterances = utterances
    }

    /// The whole reference transcript.
    public var reference: String {
        utterances.map(\.text).joined(separator: " ")
    }

    public var sampleCount: Int64 { Int64(samples.count) }

    public var duration: Duration {
        .samples(sampleCount, sampleRate: AudioFrame.captureSampleRate)
    }

    /// Checks the labels: text present, in order, not overlapping, inside
    /// the audio.
    public func validate() throws(ASREvaluationDatasetError) {
        guard !utterances.isEmpty else { throw .invalidUtterance(fixture: id, reason: "no utterances") }
        var previousEnd: Int64 = 0
        for (index, utterance) in utterances.enumerated() {
            let label = "utterance \(index + 1)"
            guard !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .invalidUtterance(fixture: id, reason: "\(label) has no text")
            }
            guard utterance.range.lowerBound >= previousEnd, !utterance.range.isEmpty else {
                throw .invalidUtterance(fixture: id, reason: "\(label) is empty, out of order or overlapping")
            }
            guard utterance.range.upperBound <= sampleCount else {
                throw .invalidUtterance(
                    fixture: id,
                    reason: "\(label) ends at \(utterance.range.upperBound), after the audio (\(sampleCount) samples)")
            }
            previousEnd = utterance.range.upperBound
        }
    }
}

/// A validated evaluation set.
public struct ASREvaluationDataset: Sendable {
    public let name: String
    public let consent: String
    public let fixtures: [ASREvaluationFixture]

    public init(name: String, consent: String, fixtures: [ASREvaluationFixture]) throws(ASREvaluationDatasetError) {
        guard !consent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .missingConsent }
        guard !fixtures.isEmpty else { throw .noFixtures }
        var seen = Set<String>()
        for fixture in fixtures {
            guard seen.insert(fixture.id).inserted else { throw .duplicateFixture(fixture.id) }
            try fixture.validate()
        }
        self.name = name
        self.consent = consent
        self.fixtures = fixtures
    }

    /// Categories in order of first appearance.
    public var categories: [String] {
        var seen = Set<String>()
        return fixtures.map(\.category).filter { seen.insert($0).inserted }
    }

    public var audioSeconds: Double {
        Double(fixtures.reduce(0) { $0 + $1.sampleCount }) / Double(AudioFrame.captureSampleRate)
    }

    public var utteranceCount: Int {
        fixtures.reduce(0) { $0 + $1.utterances.count }
    }

    /// Reads and decodes a manifest without loading audio.
    public static func manifest(at url: URL) throws -> ASREvaluationManifest {
        try JSONDecoder().decode(ASREvaluationManifest.self, from: Data(contentsOf: url))
    }

    /// Loads the manifest at `url` and the audio of every fixture it lists.
    ///
    /// - Parameters:
    ///   - categories: Only these categories; `nil` loads everything.
    ///   - fixtureIDs: Only these fixtures; `nil` loads everything.
    public static func load(
        manifest url: URL, categories: Set<String>? = nil, fixtureIDs: Set<String>? = nil
    ) throws -> ASREvaluationDataset {
        let manifest = try manifest(at: url)
        guard !manifest.consent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASREvaluationDatasetError.missingConsent
        }
        let root = url.deletingLastPathComponent().standardizedFileURL
        let rate = manifest.sampleRate ?? AudioFrame.captureSampleRate
        let entries = manifest.fixtures.filter { entry in
            (categories?.contains(entry.category) ?? true) && (fixtureIDs?.contains(entry.id) ?? true)
        }
        let fixtures = try entries.map { entry in
            let file = try resolve(entry.path, in: root)
            let samples = try readAudio(file, path: entry.path)
            if let expected = entry.sampleCount {
                let expected16k = convert(expected, from: rate)
                // Resampling can round the length by a sample or two.
                guard abs(expected16k - Int64(samples.count)) <= 2 else {
                    throw ASREvaluationDatasetError.lengthMismatch(
                        path: entry.path, expected: expected16k, actual: Int64(samples.count))
                }
            }
            let utterances = entry.utterances.map { utterance in
                ASRReferenceUtterance(
                    range: convert(utterance.start, from: rate)..<convert(utterance.end, from: rate),
                    text: utterance.text)
            }
            return ASREvaluationFixture(
                id: entry.id, category: entry.category, description: entry.description, tags: entry.tags ?? [:],
                samples: samples, utterances: utterances)
        }
        return try ASREvaluationDataset(name: manifest.name, consent: manifest.consent, fixtures: fixtures)
    }

    /// Whether every audio file the manifest lists is present as audio (not
    /// a Git LFS pointer). Tests that need the audio check this first.
    public static func audioIsAvailable(manifest url: URL) -> Bool {
        guard let manifest = try? manifest(at: url) else { return false }
        let root = url.deletingLastPathComponent().standardizedFileURL
        return manifest.fixtures.allSatisfy { entry in
            guard let file = try? resolve(entry.path, in: root) else { return false }
            return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) && !isLFSPointer(file)
        }
    }

    /// Whether `url` holds a Git LFS pointer instead of the file's content.
    public static func isLFSPointer(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64) else { return false }
        return String(decoding: head, as: UTF8.self).hasPrefix("version https://git-lfs.github.com/spec/")
    }

    // MARK: Helpers

    /// `path` inside `root`, refusing absolute paths and `..` escapes.
    static func resolve(_ path: String, in root: URL) throws(ASREvaluationDatasetError) -> URL {
        guard !path.hasPrefix("/"), !path.isEmpty else { throw .pathOutsideDataset(path) }
        let file = root.appending(path: path).standardizedFileURL
        let rootPath = root.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard file.path(percentEncoded: false).hasPrefix(prefix) else { throw .pathOutsideDataset(path) }
        return file
    }

    private static func readAudio(_ url: URL, path: String) throws -> [Float] {
        if isLFSPointer(url) { throw ASREvaluationDatasetError.lfsPointer(path) }
        do {
            return try AudioFixture.load(contentsOf: url).samples
        } catch {
            throw ASREvaluationDatasetError.unreadableAudio(path: path, reason: error.localizedDescription)
        }
    }

    private static func convert(_ position: Int64, from rate: Int) -> Int64 {
        guard rate != AudioFrame.captureSampleRate else { return position }
        return (position * Int64(AudioFrame.captureSampleRate) + Int64(rate) / 2) / Int64(rate)
    }
}
