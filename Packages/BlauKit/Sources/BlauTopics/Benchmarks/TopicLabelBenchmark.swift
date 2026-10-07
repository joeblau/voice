import BlauCore
import BlauTelemetry
import Foundation

/// Something that labels topic requests, as the benchmark sees it. The
/// production implementation is `FoundationModelsLabelBenchmarkGenerator`,
/// which drives Blau's `FoundationModelsTopicLabeler`.
public protocol TopicLabelGenerator: Sendable {
    /// `nil` when the model can run here, otherwise why not (Apple
    /// Intelligence off, device not eligible, model still downloading).
    func unavailableReason() async -> String?
    /// A fresh session for `request`. With `prewarm`, the session starts
    /// loading the model now and returns without waiting
    /// (`LanguageModelSession.prewarm()` is fire-and-forget), so the caller
    /// must leave it time before asking (the segmenter knows a boundary is
    /// coming a moment before it asks).
    func makeSession(for request: TopicLabelRequest, prewarm: Bool) async -> any TopicLabelSession
}

/// One session from a `TopicLabelGenerator`, for the request it was made
/// for.
public protocol TopicLabelSession: Sendable {
    /// Labels the request: is it a new topic, and what is it called?
    func label() async throws -> TopicShift
}

/// Measures topic-label latency with on-device Foundation Models: the
/// first request in the process (`label.cold`, session creation included),
/// later requests in fresh sessions (`label`), and fresh sessions that were
/// prewarmed (`label.prewarmed`). Also records how often the model's raw
/// title kept to the five words the prompt asks for (before
/// `TopicTitleFormatter` enforces it).
///
/// For `label` and `label.prewarmed` the session is created (and, for the
/// latter, prewarmed) outside the timed region, then both wait
/// `prewarmLead` before the timed request, so the only difference between
/// the two is the prewarm call. The timed region is the labeler's whole
/// `label`: token counting, prompt fitting, generation and any retry.
public struct TopicLabelBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        public var iterations: Int
        public var maximumTitleWords: Int
        /// Time between creating (and prewarming) a session and the timed
        /// request: about how early the segmenter knows a boundary is
        /// coming (#52).
        public var prewarmLead: Duration

        public init(
            iterations: Int = 12,
            maximumTitleWords: Int = TopicTitleFormatter.maximumWords,
            prewarmLead: Duration = .seconds(1.5)
        ) {
            self.iterations = iterations
            self.maximumTitleWords = maximumTitleWords
            self.prewarmLead = prewarmLead
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .topics }

    private let generator: any TopicLabelGenerator
    private let requests: [TopicLabelRequest]
    private let configuration: Configuration
    private let signposter: Signposter

    public init(
        id: String = "topics.label.foundationModels",
        title: String = "Foundation Models topic label",
        generator: any TopicLabelGenerator,
        requests: [TopicLabelRequest] = TopicLabelRequest.benchmarkRequests,
        configuration: Configuration = Configuration(),
        signposter: Signposter = Signposts.topics
    ) {
        precondition(!requests.isEmpty, "The benchmark needs at least one request")
        self.id = id
        self.title = title
        self.generator = generator
        self.requests = requests
        self.configuration = configuration
        self.signposter = signposter
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        if let reason = await generator.unavailableReason() {
            throw BenchmarkSkip("Foundation Models unavailable: \(reason)")
        }
        var memory = context.memoryWatermark()

        recorder.progress(0, "First request")
        let (firstShift, cold) = try await context.measure {
            try await signposter.withInterval(.topicsLabel) {
                try await generator.makeSession(for: requests[0], prewarm: false).label()
            }
        }
        recorder.record("label.cold", cold)
        memory.sample()

        var shifts = [firstShift]
        var plain: [Duration] = []
        var prewarmed: [Duration] = []
        let total = configuration.iterations * 2
        for iteration in 0..<configuration.iterations {
            for prewarm in [false, true] {
                try Task.checkCancellation()
                let request = requests[(iteration + 1) % requests.count]
                let session = await generator.makeSession(for: request, prewarm: prewarm)
                try await context.clock.sleep(for: configuration.prewarmLead)
                let (shift, elapsed) = try await context.measure {
                    try await signposter.withInterval(.topicsLabel) { try await session.label() }
                }
                shifts.append(shift)
                if prewarm { prewarmed.append(elapsed) } else { plain.append(elapsed) }
                let done = iteration * 2 + (prewarm ? 2 : 1)
                recorder.progress(Double(done) / Double(total), "Request \(done) of \(total)")
            }
        }
        recorder.recordLatencies("label", plain)
        recorder.recordLatencies("label.prewarmed", prewarmed)

        let compliant = shifts.count {
            (1...configuration.maximumTitleWords).contains(TopicTitleFormatter.wordCount($0.title))
        }
        recorder.record("titles.withinWordLimit", Double(compliant) / Double(shifts.count) * 100, unit: .percent)
        recorder.note(
            "\(requests.count) fixture boundary requests; \(configuration.prewarmLead) lead before each timed "
                + "request; titles are not logged")
        memory.sample()
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }
}

extension TopicLabelRequest {
    /// Invented boundary requests, some real topic changes and some not,
    /// shaped like the ones the segmenter sends (#52): three exchanges
    /// either side of the boundary (`TopicLabelRequest.boundary`'s six
    /// context units), each a user turn and the assistant's reply.
    public static let benchmarkRequests: [TopicLabelRequest] = [
        benchmarkRequest(
            previousTitle: "Beta Launch Date",
            before: [
                (
                    "We moved the beta to October twenty first because onboarding still takes too long.",
                    "That gives the team two more weeks. Is onboarding the only blocker?"
                ),
                (
                    "Mostly. Forty percent of new people dropped off before finishing their voice sample.",
                    "That is a big drop. Shortening the sample to three sentences could help."
                ),
                (
                    "Good idea, I'll ask design for a shorter version.",
                    "Sounds good. I can draft the three sentences if you want."
                ),
            ],
            after: [
                (
                    "Anyway, my sister is visiting next weekend and I want to plan Saturday.",
                    "Fun! What does she like to do?"
                ),
                (
                    "She loves art, so maybe brunch near the park and then the museum if it rains.",
                    "The museum has a new photography exhibit that opened this month."
                ),
                (
                    "Perfect, can you check if we need tickets?",
                    "Timed tickets are recommended on weekends, so booking ahead is safer."
                ),
            ]),
        benchmarkRequest(
            previousTitle: "Subscription Pricing",
            before: [
                (
                    "The pricing page has a monthly plan at nine dollars.",
                    "And the annual plan is ninety, so two months free."
                ),
                (
                    "Right. We still need to decide whether the annual plan gets a free trial.",
                    "Trials usually lift annual conversions, but they delay revenue."
                ),
                (
                    "I'm worried people will cancel before the trial ends.",
                    "A reminder email two days before it ends keeps that honest."
                ),
            ],
            after: [
                (
                    "What if the trial is fourteen days and only on the annual plan?",
                    "That keeps the monthly plan simple and rewards committing."
                ),
                (
                    "Would we still show the monthly price first?",
                    "Showing annual first with the monthly equivalent tends to work better."
                ),
                (
                    "Okay, let's mock both layouts.",
                    "I'll list what each layout needs to show."
                ),
            ]),
        benchmarkRequest(
            previousTitle: "Morning Run",
            before: [
                (
                    "I ran five miles this morning and my knee felt fine for once.",
                    "Nice! Was that on the trail or the road?"
                ),
                (
                    "The road. I think the new shoes are helping.",
                    "More cushioning can make a real difference on pavement."
                ),
                (
                    "I might try six on Sunday.",
                    "Adding a mile a week is a safe way to build up."
                ),
            ],
            after: [
                (
                    "Can you help me get ready for the interview on Thursday?",
                    "Of course. What is the role, and who is interviewing you?"
                ),
                (
                    "It's the product lead role. They will ask how we are different from the big assistants.",
                    "Lead with what only you do: everything runs on the phone and stays private."
                ),
                (
                    "Can we practice that answer out loud?",
                    "Yes. Give me your version and I'll play the interviewer."
                ),
            ]),
        benchmarkRequest(
            previousTitle: "Banana Bread Recipe",
            before: [
                (
                    "The recipe needs two cups of flour and a teaspoon of baking soda.",
                    "And three ripe bananas, mashed."
                ),
                (
                    "Bake it at three fifty for about forty minutes?",
                    "Yes, until a toothpick comes out clean."
                ),
                (
                    "My oven runs hot, though.",
                    "Then start checking at thirty five minutes."
                ),
            ],
            after: [
                (
                    "Should I use brown sugar instead of white sugar?",
                    "Brown sugar makes it moister with a slight caramel taste."
                ),
                (
                    "And can I swap the butter for olive oil?",
                    "Yes, use about three quarters as much oil as butter."
                ),
                (
                    "Will it still rise the same?",
                    "It will be a little denser, but it rises fine."
                ),
            ]),
    ]

    /// A boundary request from (user, assistant) exchanges, spaced 20 s
    /// apart on the audio timeline.
    static func benchmarkRequest(
        previousTitle: String,
        before: [(user: String, agent: String)],
        after: [(user: String, agent: String)]
    ) -> TopicLabelRequest {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let units = (before + after).enumerated().map { index, exchange in
            TopicUnit(
                userText: exchange.user, agentText: exchange.agent,
                timeRange: TimeRange(start: .seconds(index * 20), end: .seconds(index * 20 + 18)),
                startedAt: start.addingTimeInterval(Double(index * 20)))
        }
        return TopicLabelRequest(
            kind: .boundary, before: Array(units[..<before.count]), after: Array(units[before.count...]),
            previousTitle: previousTitle, confirmsBoundary: true)
    }
}
