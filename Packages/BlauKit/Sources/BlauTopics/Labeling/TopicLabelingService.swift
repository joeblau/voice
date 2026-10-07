import BlauCore
import BlauTelemetry
import Foundation
import os

/// Labels topics with the best labeler available, falling back down the
/// chain, and records how long it took.
///
/// The standard chain (`standard(textGenerator:onDevice:)`):
///
/// 1. `FoundationModelsTopicLabeler`: Apple's on-device model.
/// 2. `RemoteTopicLabeler` over `XAITextGenerator`: when Apple Intelligence
///    is unavailable (device not eligible, turned off, model not ready) or
///    fails, and the user has stored an xAI key.
/// 3. `KeywordTopicLabeler`: always works.
///
/// Each labeler is skipped if it isn't available, and abandoned after
/// `timeout`, on error, or when its title is unusable. Every label goes
/// through `TopicTitleFormatter`, so titles are at most five words whichever
/// labeler wrote them.
///
/// The thermal policy decides how much inference to spend: confirmation is
/// skipped at `.serious` and only keyword labels are made at `.critical`.
///
/// Each call runs inside the `topics.label` signpost interval, and its
/// latency is kept per source (`latency(for:)`) for the p50.
public actor TopicLabelingService {
    private let labelers: [any TopicLabeler]
    private let keywords: KeywordTopicLabeler
    public let policy: TopicLabelingPolicy
    private let thermal: any ThermalStateProviding
    private let clock: any BlauClock
    private let signposter: Signposter

    /// How long one labeler may take before the next one is tried.
    public let timeout: Duration

    private var latencies: [TopicLabelSource: LatencyStatistics] = [:]
    private var allLatencies = LatencyStatistics()

    /// - Parameters:
    ///   - labelers: Tried in order. The keyword labeler is always tried
    ///     last and needn't be listed.
    public init(
        labelers: [any TopicLabeler],
        keywords: KeywordTopicLabeler = KeywordTopicLabeler(),
        policy: TopicLabelingPolicy = .default,
        thermal: any ThermalStateProviding = SystemThermalState(),
        clock: any BlauClock = SystemClock(),
        timeout: Duration = .seconds(10),
        signposter: Signposter = Signposts.topics
    ) {
        self.labelers = labelers.filter { $0.source != .keywords }
        self.keywords = keywords
        self.policy = policy
        self.thermal = thermal
        self.clock = clock
        self.timeout = timeout
        self.signposter = signposter
    }

    /// `onDevice` (Foundation Models by default), then `textGenerator`
    /// (xAI) if given, then keywords.
    ///
    /// - Parameters:
    ///   - onDevice: The first labeler tried. Defaults to
    ///     `defaultOnDeviceLabeler()`. Tests pass a fake so they never run
    ///     the real model.
    public static func standard(
        textGenerator: (any TextGenerator)?,
        onDevice: (any TopicLabeler)? = defaultOnDeviceLabeler(),
        policy: TopicLabelingPolicy = .default,
        thermal: any ThermalStateProviding = SystemThermalState()
    ) -> TopicLabelingService {
        var labelers: [any TopicLabeler] = []
        if let onDevice {
            labelers.append(onDevice)
        }
        if let textGenerator {
            labelers.append(RemoteTopicLabeler(generator: textGenerator))
        }
        return TopicLabelingService(labelers: labelers, policy: policy, thermal: thermal)
    }

    /// Apple's on-device model where the SDK has FoundationModels, else
    /// `nil`. Building it runs no inference.
    public static func defaultOnDeviceLabeler() -> (any TopicLabeler)? {
        #if canImport(FoundationModels)
            FoundationModelsTopicLabeler()
        #else
            nil
        #endif
    }

    /// What the thermal policy allows right now.
    public var mode: TopicLabelingMode { policy.mode(for: thermal.thermalState) }

    /// Recent latencies of labels from `source`.
    public func latency(for source: TopicLabelSource) -> LatencyStatistics {
        latencies[source] ?? LatencyStatistics()
    }

    /// Recent latencies of every label, whichever source answered.
    public var overallLatency: LatencyStatistics { allLatencies }

    /// Labels `request`. Never fails: the keyword labeler is the floor.
    ///
    /// In `.skipConfirmation` mode the request's `confirmsBoundary` is
    /// turned off; in `.keywordsOnly` mode only keywords are used.
    public func label(_ request: TopicLabelRequest) async -> TopicLabelResult {
        let start = clock.uptime
        let result = await signposter.withInterval(.topicsLabel) {
            await runChain(request, mode: mode)
        }
        let latency = clock.uptime - start
        latencies[result.label.source, default: LatencyStatistics()].record(latency)
        allLatencies.record(latency)
        Log.topics.info(
            """
            Topic label from \(result.label.source.rawValue, privacy: .public) in \
            \(latency.milliseconds, privacy: .public) ms (p50 \
            \(self.latency(for: result.label.source).p50?.milliseconds ?? 0, privacy: .public) ms): \
            new topic \(result.isNewTopic, privacy: .public), judged \(result.wasJudged, privacy: .public), \
            "\(result.label.title, privacy: .private)"
            """
        )
        return TopicLabelResult(
            isNewTopic: result.isNewTopic, label: result.label, wasJudged: result.wasJudged, latency: latency)
    }

    private func runChain(_ original: TopicLabelRequest, mode: TopicLabelingMode) async -> TopicLabelResult {
        var request = original
        if mode != .full {
            request.confirmsBoundary = false
        }
        let judges = request.kind == .boundary && request.confirmsBoundary

        if mode != .keywordsOnly {
            let request = request
            for labeler in labelers {
                guard await labeler.isAvailable() else {
                    Log.topics.debug("Topic labeler \(labeler.source.rawValue, privacy: .public) unavailable")
                    continue
                }
                do {
                    let shift = try await withDeadline(timeout, clock: clock) { try await labeler.label(request) }
                    guard let title = TopicTitleFormatter.title(shift.title) else {
                        Log.topics.error("Topic labeler \(labeler.source.rawValue, privacy: .public) gave no title")
                        continue
                    }
                    let summary =
                        TopicTitleFormatter.summary(shift.summary)
                        ?? TopicTitleFormatter.summary(keywords.shift(for: request).summary) ?? ""
                    return TopicLabelResult(
                        isNewTopic: judges ? shift.isNewTopic : true,
                        label: TopicLabel(title: title, summary: summary, source: labeler.source),
                        wasJudged: judges,
                        latency: .zero
                    )
                } catch is CancellationError {
                    break
                } catch {
                    Log.topics.error(
                        """
                        Topic labeler \(labeler.source.rawValue, privacy: .public) failed with \
                        \(String(describing: type(of: error)), privacy: .public): \
                        \(String(describing: error), privacy: .private)
                        """
                    )
                }
            }
        }

        let shift = keywords.shift(for: request)
        return TopicLabelResult(
            isNewTopic: true,
            label: TopicLabel(
                title: TopicTitleFormatter.title(shift.title) ?? KeywordTopicLabeler.untitled,
                summary: TopicTitleFormatter.summary(shift.summary) ?? "",
                source: .keywords
            ),
            wasJudged: false,
            latency: .zero
        )
    }
}

extension Duration {
    /// Whole milliseconds, for logs.
    var milliseconds: Int64 {
        let parts = components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
