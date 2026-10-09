import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Adaptive voiceprint updates (#49) for one conversation: takes the
/// segments the verification gate accepted, measures their level, offers
/// them to the ``AdaptiveVoiceprint`` the verifier scores against, logs
/// every update, and saves the adapted centroid when the conversation ends.
///
/// ```swift
/// let verifier = try SpeakerVerifier(embedder: embedder, voiceprint: voiceprint, adaptation: .standard)
/// let adapter = verifier.adaptive.map { VoiceprintAdapter(voiceprint: $0, store: store) }
/// let gate = VerificationGate(verifier: verifier, history: hub, onScoredSpeech: adapter.map { a in { a.observe($0) } })
/// // ... the conversation ...
/// await adapter?.finish()                     // saves, unless rolled back
/// ```
///
/// Segments are handled in order on the adapter's own actor, never on the
/// gate's, so adapting adds nothing to the gate's hold on a final. Updates
/// stay in memory until ``finish()``: the stored centroid is the rollback
/// snapshot, and a conversation whose updates were rolled back saves
/// nothing.
public actor VoiceprintAdapter {
    /// What a conversation's adaptation came to.
    public struct Summary: Hashable, Sendable {
        /// Updates applied (and saved, if ``saved``).
        public var updates = 0
        /// Of those, updates the drift cap pulled back.
        public var capped = 0
        /// Segments that didn't move the centroid, by reason.
        public var skips: [VoiceprintAdaptation.SkipReason: Int] = [:]
        /// The centroid's distance from the enrollment centroid at the end.
        public var drift: Float = 0
        /// Whether the conversation's updates were rolled back.
        public var rolledBack = false
        /// Whether the adapted centroid was saved.
        public var saved = false

        public init() {}

        /// Segments offered.
        public var segments: Int { updates + skips.values.reduce(0, +) }
    }

    /// The voiceprint the verifier scores against.
    public nonisolated let voiceprint: AdaptiveVoiceprint
    private let store: (any VoiceprintStoring)?
    private let analyzer: EnrollmentLevelAnalyzer
    private let now: @Sendable () -> Date
    private nonisolated let input: AsyncStream<ScoredSpeechSegment>.Continuation
    private nonisolated let drain = Mutex<Task<Void, Never>?>(nil)
    private var finished: Summary?
    private var segmentsSeen = 0

    /// - Parameters:
    ///   - voiceprint: The verifier's ``SpeakerVerifier/adaptive``.
    ///   - store: Where the adapted centroid is saved at the end; `nil`
    ///     keeps it in memory (tests, replays).
    ///   - analyzer: Measures each segment's speech and noise level.
    ///   - now: The date stamped on the saved centroid.
    public init(
        voiceprint: AdaptiveVoiceprint,
        store: (any VoiceprintStoring)?,
        analyzer: EnrollmentLevelAnalyzer = EnrollmentLevelAnalyzer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.voiceprint = voiceprint
        self.store = store
        self.analyzer = analyzer
        self.now = now
        // A long monologue gives a segment every few seconds and each takes
        // well under a millisecond; the bound only matters if the adapter
        // is starved, and then dropping the oldest is harmless.
        let (stream, input) = AsyncStream.makeStream(
            of: ScoredSpeechSegment.self, bufferingPolicy: .bufferingNewest(32))
        self.input = input
        drain.withLock { task in
            task = Task { [weak self] in
                for await segment in stream {
                    await self?.handle(segment)
                }
            }
        }
    }

    deinit {
        input.finish()
    }

    /// Takes one segment the gate accepted: the gate's `onScoredSpeech`.
    /// Returns at once; the segment is handled in order on the adapter.
    public nonisolated func observe(_ segment: ScoredSpeechSegment) {
        input.yield(segment)
    }

    /// Handles one segment now (``observe(_:)`` queues it instead).
    @discardableResult
    public func handle(_ segment: ScoredSpeechSegment) -> VoiceprintAdaptation.Outcome? {
        guard finished == nil, let embedding = segment.score.embedding else { return nil }
        segmentsSeen += 1
        let level = analyzer.analyze(segment.audio)
        let evidence = VoiceprintAdaptationEvidence(
            embedding: embedding, score: segment.score.score, thresholds: segment.score.thresholds,
            speechDuration: segment.speechDuration, signalToNoise: level.hasSpeech ? level.signalToNoise : nil,
            clippedFraction: level.clippedFraction)
        let outcome = voiceprint.consider(evidence)
        log(outcome, segment: segment, signalToNoise: evidence.signalToNoise)
        return outcome
    }

    /// Ends the conversation's adaptation: handles the segments still
    /// queued, then saves the adapted centroid unless nothing changed or
    /// the updates were rolled back. Later calls return the same summary.
    @discardableResult
    public func finish() async -> Summary {
        if let finished { return finished }
        input.finish()
        let task = drain.withLock { $0 }
        await task?.value
        if let finished { return finished }

        let adaptation = voiceprint.adaptation
        var summary = Summary()
        summary.updates = adaptation.updateCount
        summary.capped = adaptation.cappedCount
        summary.skips = adaptation.skips
        summary.drift = adaptation.drift
        summary.rolledBack = adaptation.isRolledBack
        if adaptation.hasChanges, let store {
            let update = AdaptedVoiceprintCentroid(
                voiceprintID: voiceprint.voiceprint.id, centroid: adaptation.centroid,
                maximumDrift: adaptation.policy.maximumDrift, adaptedAt: now())
            do {
                try await store.saveAdaptedCentroid(update)
                summary.saved = true
            } catch {
                Log.voiceID.error(
                    "Voiceprint adaptation not saved: \(String(describing: error), privacy: .public)")
            }
        }
        finished = summary
        Log.voiceID.notice(
            """
            Voiceprint adaptation for this conversation: \(summary.updates, privacy: .public) update(s) \
            (\(summary.capped, privacy: .public) capped) from \(self.segmentsSeen, privacy: .public) accepted segment(s), \
            drift \(summary.drift, format: .fixed(precision: 4), privacy: .public), \
            \(summary.rolledBack ? "rolled back" : summary.saved ? "saved" : "not saved", privacy: .public); \
            skipped: \(Self.describe(summary.skips), privacy: .public)
            """
        )
        return summary
    }

    // MARK: Logging

    private func log(_ outcome: VoiceprintAdaptation.Outcome, segment: ScoredSpeechSegment, signalToNoise: Float?) {
        let snr = signalToNoise.map { String(format: "%.1f dB", $0) } ?? "–"
        switch outcome {
        case .updated(let update):
            Log.voiceID.notice(
                """
                Voiceprint adapted (update \(update.count, privacy: .public)) from segment \(segment.segmentID, privacy: .public): \
                score \(update.score, format: .fixed(precision: 3), privacy: .public), \
                enrollment score \(update.enrollmentScore, format: .fixed(precision: 3), privacy: .public), \
                SNR \(snr, privacy: .public), \
                step \(update.step, format: .fixed(precision: 5), privacy: .public), \
                drift \(update.drift, format: .fixed(precision: 4), privacy: .public)\
                \(update.isCapped ? " (capped)" : "", privacy: .public)
                """
            )
        case .skipped(let reason):
            Log.voiceID.debug(
                """
                Segment \(segment.segmentID, privacy: .public) not used to adapt the voiceprint: \
                \(reason.rawValue, privacy: .public) (score \(segment.score.score, format: .fixed(precision: 3), privacy: .public), \
                SNR \(snr, privacy: .public))
                """
            )
        case .rolledBack(let health):
            Log.voiceID.notice(
                """
                Voiceprint adaptation rolled back at segment \(segment.segmentID, privacy: .public): the owner's speech \
                fit the adapted centroid worse than the conversation's starting one \
                (mean gain \(health.meanGain, format: .fixed(precision: 4), privacy: .public) over \
                \(health.samples, privacy: .public) segment(s)); not adapting until the next conversation
                """
            )
        }
    }

    private static func describe(_ skips: [VoiceprintAdaptation.SkipReason: Int]) -> String {
        let parts = VoiceprintAdaptation.SkipReason.allCases.compactMap { reason in
            skips[reason].map { "\(reason.rawValue) \($0)" }
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
