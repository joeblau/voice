import BlauCore
import BlauTelemetry
import Foundation

/// The on-device language model's verdict on a candidate topic boundary
/// (#53): is it a new topic, and what is it called?
public struct TopicLabelDraft: Hashable, Sendable {
    public var isNewTopic: Bool
    public var title: String

    public init(isNewTopic: Bool, title: String) {
        self.isNewTopic = isNewTopic
        self.title = title
    }

    /// Words in the title.
    public var titleWordCount: Int {
        title.split(whereSeparator: \.isWhitespace).count
    }
}

/// Something that confirms and titles a candidate boundary, as the benchmark
/// sees it. The production implementation is
/// `FoundationModelsTopicLabeler`.
public protocol TopicLabelGenerator: Sendable {
    /// `nil` when the model can run here, otherwise why not (Apple
    /// Intelligence off, device not eligible, model still downloading).
    func unavailableReason() async -> String?
    /// Labels one candidate boundary in a fresh session. With `prewarm`, the
    /// session loads the model before the timed request starts (the
    /// segmenter knows a boundary is coming a moment before it asks).
    func label(_ window: TopicBoundaryWindow, prewarm: Bool) async throws -> TopicLabelDraft
}

/// The text around a candidate boundary: the exchanges before it and the
/// exchanges after it.
public struct TopicBoundaryWindow: Hashable, Sendable {
    public var before: [String]
    public var after: [String]

    public init(before: [String], after: [String]) {
        self.before = before
        self.after = after
    }
}

/// Measures topic-label latency with on-device Foundation Models: the
/// first request in the process (`label.cold`), later requests in fresh
/// sessions (`label`), and fresh sessions that were prewarmed
/// (`label.prewarmed`). Also records how often the title kept to the five
/// words the prompt asks for.
public struct TopicLabelBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        public var iterations: Int
        public var maximumTitleWords: Int

        public init(iterations: Int = 12, maximumTitleWords: Int = 5) {
            self.iterations = iterations
            self.maximumTitleWords = maximumTitleWords
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .topics }

    private let generator: any TopicLabelGenerator
    private let windows: [TopicBoundaryWindow]
    private let configuration: Configuration
    private let signposter: Signposter

    public init(
        id: String = "topics.label.foundationModels",
        title: String = "Foundation Models topic label",
        generator: any TopicLabelGenerator,
        windows: [TopicBoundaryWindow] = TopicBoundaryWindow.benchmarkWindows,
        configuration: Configuration = Configuration(),
        signposter: Signposter = Signposts.topics
    ) {
        precondition(!windows.isEmpty, "The benchmark needs at least one window")
        self.id = id
        self.title = title
        self.generator = generator
        self.windows = windows
        self.configuration = configuration
        self.signposter = signposter
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        if let reason = await generator.unavailableReason() {
            throw BenchmarkSkip("Foundation Models unavailable: \(reason)")
        }
        var memory = context.memoryWatermark()

        recorder.progress(0, "First request")
        let (firstDraft, cold) = try await context.measure {
            try await signposter.withInterval(.topicsLabel) { try await generator.label(windows[0], prewarm: false) }
        }
        recorder.record("label.cold", cold)
        memory.sample()

        var drafts = [firstDraft]
        var plain: [Duration] = []
        var prewarmed: [Duration] = []
        let total = configuration.iterations * 2
        for iteration in 0..<configuration.iterations {
            for prewarm in [false, true] {
                try Task.checkCancellation()
                let window = windows[(iteration + 1) % windows.count]
                let (draft, elapsed) = try await context.measure {
                    try await signposter.withInterval(.topicsLabel) {
                        try await generator.label(window, prewarm: prewarm)
                    }
                }
                drafts.append(draft)
                if prewarm { prewarmed.append(elapsed) } else { plain.append(elapsed) }
                let done = iteration * 2 + (prewarm ? 2 : 1)
                recorder.progress(Double(done) / Double(total), "Request \(done) of \(total)")
            }
        }
        recorder.recordLatencies("label", plain)
        recorder.recordLatencies("label.prewarmed", prewarmed)

        let compliant = drafts.count { (1...configuration.maximumTitleWords).contains($0.titleWordCount) }
        recorder.record("titles.withinWordLimit", Double(compliant) / Double(drafts.count) * 100, unit: .percent)
        recorder.note("\(windows.count) fixture boundary windows; titles are not logged")
        memory.sample()
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }
}

extension TopicBoundaryWindow {
    /// Short invented exchanges around boundaries, some real topic changes
    /// and some not, sized like the windows the segmenter sends (#52).
    public static let benchmarkWindows: [TopicBoundaryWindow] = [
        TopicBoundaryWindow(
            before: [
                "We moved the beta to October twenty first because onboarding still takes too long.",
                "Forty percent of new people dropped off before finishing their voice sample.",
            ],
            after: [
                "Anyway, my sister is visiting next weekend and I want to plan Saturday.",
                "Maybe brunch near the park and then the museum if it rains.",
            ]),
        TopicBoundaryWindow(
            before: [
                "The pricing page has a monthly plan at nine dollars.",
                "We still need to decide whether the annual plan gets a free trial.",
            ],
            after: [
                "What if the trial is fourteen days and only on the annual plan?",
                "That way the monthly plan stays simple.",
            ]),
        TopicBoundaryWindow(
            before: [
                "I ran five miles this morning and my knee felt fine for once.",
                "I think the new shoes are helping.",
            ],
            after: [
                "Can you help me get ready for the interview on Thursday?",
                "They will ask how we are different from the big assistants.",
            ]),
        TopicBoundaryWindow(
            before: [
                "The recipe needs two cups of flour and a teaspoon of baking soda.",
                "Bake it at three fifty for about forty minutes.",
            ],
            after: [
                "Should I use brown sugar instead of white sugar?",
                "And can I swap the butter for olive oil?",
            ]),
    ]
}
