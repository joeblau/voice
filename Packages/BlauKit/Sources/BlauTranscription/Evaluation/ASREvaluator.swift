import BlauCore
import BlauTelemetry
import Foundation

/// Runs ASR engines over an evaluation set and measures them (#32).
///
/// For every engine and fixture:
///
/// - **WER**: the finals' text against the reference, both through
///   `TranscriptNormalizer`, as substitution, deletion and insertion counts
///   that add up across fixtures (corpus WER).
/// - **First-partial latency** (streaming engines): from the start of an
///   utterance's speech to the first partial that covers it.
/// - **End-of-utterance latency**: from the end of an utterance's speech to
///   the last final that covers it, the moment the turn can be sent.
/// - **RTF**: compute time over audio time (below 1 is faster than real
///   time).
///
/// Latencies are reported twice: in total (audio position plus the compute
/// of the emitting call, see `ASRTimedEvent`) and in audio time only, which
/// depends on the algorithm (chunking, VAD, endpointing delays) and not on
/// the hardware, so it can be gated tightly on any machine.
///
/// An utterance with no final over it is **missed**; one covered by more
/// than one final was **split** (an end of utterance detected mid-sentence);
/// one a streaming engine only finalized because the audio ended is
/// **unended**: neither the model nor VAD found its end (steady background
/// speech keeps VAD's segment open), so live it would have waited for the
/// 30 s limit. Its latency would only measure the fixture's length, so it
/// is left out of the end-of-utterance summaries and counted instead.
/// An engine that throws on a fixture records the error and an empty
/// transcript for it.
public struct ASREvaluator: Sendable {
    public let dataset: ASREvaluationDataset
    public let normalizer: TranscriptNormalizer

    public init(dataset: ASREvaluationDataset, normalizer: TranscriptNormalizer = TranscriptNormalizer()) {
        self.dataset = dataset
        self.normalizer = normalizer
    }

    /// Evaluates every engine in turn.
    ///
    /// - Parameter progress: Called with a line of progress per fixture.
    public func run(
        _ engines: [any ASREvaluationEngine],
        device: BenchmarkDevice = .current,
        commit: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ASREvaluationReport {
        var reports: [ASREngineReport] = []
        for engine in engines {
            reports.append(try await evaluate(engine, progress: progress))
        }
        return ASREvaluationReport(
            generatedAt: Date(), device: device, commit: commit,
            dataset: ASRDatasetSummary(
                name: dataset.name, fixtures: dataset.fixtures.count, utterances: dataset.utteranceCount,
                audioSeconds: dataset.audioSeconds, categories: dataset.categories),
            engines: reports)
    }

    /// Evaluates one engine over the whole set.
    public func evaluate(
        _ engine: any ASREvaluationEngine, progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ASREngineReport {
        let id = engine.descriptor.id
        progress?("[\(id)] preparing")
        try await engine.prepare()
        var results: [ASRFixtureResult] = []
        for (index, fixture) in dataset.fixtures.enumerated() {
            let result: ASRFixtureResult
            do {
                let transcript = try await engine.transcribe(fixture)
                result = score(transcript, for: fixture, kind: engine.descriptor.kind)
            } catch {
                result = score(ASREngineTranscript(events: [], computeTime: .zero), for: fixture, error: error)
            }
            results.append(result)
            progress?(
                "[\(id)] \(index + 1)/\(dataset.fixtures.count) \(fixture.id): WER \(Self.percent(result.counts.wordErrorRate))"
                    + (result.error.map { ", failed: \($0)" } ?? ""))
        }
        return ASREngineReport(descriptor: engine.descriptor, fixtures: results, categoryOrder: dataset.categories)
    }

    /// Measures one engine transcript against its fixture.
    public func score(
        _ transcript: ASREngineTranscript, for fixture: ASREvaluationFixture,
        kind: ASREngineDescriptor.Kind = .streaming, error: (any Error)? = nil
    ) -> ASRFixtureResult {
        let hypothesis = transcript.hypothesis
        let counts = WordErrorCounts(
            reference: normalizer.words(fixture.reference), hypothesis: normalizer.words(hypothesis))
        let rate = Double(AudioFrame.captureSampleRate)

        let utterances = fixture.utterances.enumerated().map { index, utterance -> ASRUtteranceResult in
            let next = index + 1 < fixture.utterances.count ? fixture.utterances[index + 1].range.lowerBound : nil
            // The first partial about this utterance: it covers some of its
            // speech and came out before the next utterance began.
            let partial = transcript.partials.first { event in
                event.range.touches(utterance.range) && event.audioPosition > utterance.range.lowerBound
                    && next.map { event.audioPosition <= $0 } ?? true
            }
            let finals = transcript.finals.filter { $0.range.touches(utterance.range) && !$0.text.isEmpty }
            let last = finals.max { $0.availableAt < $1.availableAt }

            func milliseconds(_ event: ASRTimedEvent, from reference: Int64) -> (total: Double, audio: Double) {
                let audio = Double(event.audioPosition - reference) / rate * 1_000
                return (max(0, audio + event.computeLag.milliseconds), max(0, audio))
            }
            let first = partial.map { milliseconds($0, from: utterance.range.lowerBound) }
            let end = last.map { milliseconds($0, from: utterance.range.upperBound) }
            return ASRUtteranceResult(
                firstPartialMilliseconds: first?.total, firstPartialAudioMilliseconds: first?.audio,
                endOfUtteranceMilliseconds: end?.total, endOfUtteranceAudioMilliseconds: end?.audio,
                finals: finals.count,
                endedByStreamEnd: kind == .streaming && (last.map { $0.audioPosition >= fixture.sampleCount } ?? false))
        }

        return ASRFixtureResult(
            id: fixture.id, category: fixture.category, reference: fixture.reference, hypothesis: hypothesis,
            counts: counts, utterances: utterances, audioSeconds: fixture.duration.timeInterval,
            computeSeconds: transcript.computeTime.timeInterval,
            error: error.map { String(describing: $0) })
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

/// One fixture's results for one engine.
public struct ASRFixtureResult: Codable, Hashable, Sendable {
    public var id: String
    public var category: String
    public var reference: String
    /// What the engine transcribed (its finals joined).
    public var hypothesis: String
    public var counts: WordErrorCounts
    public var utterances: [ASRUtteranceResult]
    public var audioSeconds: Double
    public var computeSeconds: Double
    /// Why the engine failed on this fixture, if it did.
    public var error: String?

    public var realTimeFactor: Double {
        audioSeconds > 0 ? computeSeconds / audioSeconds : 0
    }
}

/// Timing for one reference utterance. `nil` where the engine produced no
/// such event (an offline engine has no partials; a missed utterance no
/// final).
public struct ASRUtteranceResult: Codable, Hashable, Sendable {
    /// Start of speech to the first partial, compute included.
    public var firstPartialMilliseconds: Double?
    /// The same in audio time only.
    public var firstPartialAudioMilliseconds: Double?
    /// End of speech to the last final covering the utterance, compute
    /// included.
    public var endOfUtteranceMilliseconds: Double?
    /// The same in audio time only.
    public var endOfUtteranceAudioMilliseconds: Double?
    /// Finals that cover the utterance: 0 is a miss, more than 1 a split.
    public var finals: Int
    /// Whether a streaming engine only finalized it because the audio
    /// ended.
    public var endedByStreamEnd: Bool
}

/// Aggregated metrics over a set of fixtures.
public struct ASRMetrics: Codable, Hashable, Sendable {
    public var fixtures: Int
    public var utterances: Int
    public var counts: WordErrorCounts
    public var firstPartial: LatencySummary?
    public var firstPartialAudio: LatencySummary?
    /// Over the utterances whose end was detected (unended ones excluded).
    public var endOfUtterance: LatencySummary?
    public var endOfUtteranceAudio: LatencySummary?
    /// Utterances with no final.
    public var missedUtterances: Int
    /// Utterances split over several finals.
    public var splitUtterances: Int
    /// Utterances finalized only by the end of the audio (streaming).
    public var unendedUtterances: Int
    /// Fixtures the engine threw on.
    public var failures: Int
    public var audioSeconds: Double
    public var computeSeconds: Double
    /// `counts.wordErrorRate`, stored so the JSON carries it.
    public var wordErrorRate: Double
    /// Compute over audio: 0.1 means ten times faster than real time.
    public var realTimeFactor: Double

    public init(_ results: [ASRFixtureResult]) {
        let utterances = results.flatMap(\.utterances)
        fixtures = results.count
        self.utterances = utterances.count
        counts = results.reduce(WordErrorCounts()) { $0 + $1.counts }
        firstPartial = LatencySummary(milliseconds: utterances.compactMap(\.firstPartialMilliseconds))
        firstPartialAudio = LatencySummary(milliseconds: utterances.compactMap(\.firstPartialAudioMilliseconds))
        // Unended utterances' latency is the fixture's tail, not a measurement.
        let ended = utterances.filter { !$0.endedByStreamEnd }
        endOfUtterance = LatencySummary(milliseconds: ended.compactMap(\.endOfUtteranceMilliseconds))
        endOfUtteranceAudio = LatencySummary(milliseconds: ended.compactMap(\.endOfUtteranceAudioMilliseconds))
        missedUtterances = utterances.filter { $0.finals == 0 }.count
        splitUtterances = utterances.filter { $0.finals > 1 }.count
        unendedUtterances = utterances.filter(\.endedByStreamEnd).count
        failures = results.filter { $0.error != nil }.count
        audioSeconds = results.reduce(0) { $0 + $1.audioSeconds }
        computeSeconds = results.reduce(0) { $0 + $1.computeSeconds }
        wordErrorRate = counts.wordErrorRate
        realTimeFactor = audioSeconds > 0 ? computeSeconds / audioSeconds : 0
    }
}

/// One engine's results: overall, per category and per fixture.
public struct ASREngineReport: Codable, Hashable, Sendable {
    public var descriptor: ASREngineDescriptor
    public var overall: ASRMetrics
    public var categories: [Category]
    public var fixtures: [ASRFixtureResult]

    public struct Category: Codable, Hashable, Sendable {
        public var name: String
        public var metrics: ASRMetrics
    }

    /// - Parameter categoryOrder: How to order the categories; ones not
    ///   listed follow alphabetically.
    public init(descriptor: ASREngineDescriptor, fixtures: [ASRFixtureResult], categoryOrder: [String] = []) {
        self.descriptor = descriptor
        self.fixtures = fixtures
        overall = ASRMetrics(fixtures)
        let present = Set(fixtures.map(\.category))
        let ordered = categoryOrder.filter(present.contains) + present.subtracting(categoryOrder).sorted()
        categories = ordered.map { name in
            Category(name: name, metrics: ASRMetrics(fixtures.filter { $0.category == name }))
        }
    }

    public func metrics(for category: String) -> ASRMetrics? {
        categories.first { $0.name == category }?.metrics
    }
}

/// What was evaluated.
public struct ASRDatasetSummary: Codable, Hashable, Sendable {
    public var name: String
    public var fixtures: Int
    public var utterances: Int
    public var audioSeconds: Double
    public var categories: [String]
}

extension Range where Bound == Int64 {
    /// Whether the ranges share a sample; unlike `overlaps(_:)`, an empty
    /// range inside `other` counts (a partial whose decoded span is empty).
    fileprivate func touches(_ other: Range<Int64>) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }
}
