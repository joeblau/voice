import BlauCore
import Foundation
import Testing

@testable import BlauTopics

/// Acceptance criterion of #53: labels are at most five words for 100 % of
/// the fixtures, whichever labeler answers.
///
/// Every scripted transcript and the 60 synthetic conversations go through
/// the full pipeline (segmenter, confirmation, titles), and every reference
/// topic is also titled on its own (`labelTopic(in:)`, what #54 does when a
/// topic closes). Each run uses one labeler setup:
///
/// - keywords only (a device without Apple Intelligence or an xAI key),
/// - a model that ignores the "≤5 words" guide and answers with long,
///   decorated titles (what the formatter must catch),
/// - the xAI path, replying with the same unruly titles as JSON.
///
/// The real on-device model runs over the same fixtures in
/// `FoundationModelsTopicLabelerTests` (opt-in, `BLAU_DEVICE_TESTS=1`).
@Suite("Topic label fixtures")
struct TopicLabelFixtureTests {
    enum Setup: String, CaseIterable, CustomTestStringConvertible {
        case keywordsOnly, unrulyModel, unrulyXAI
        var testDescription: String { rawValue }

        func service() -> TopicLabelingService {
            switch self {
            case .keywordsOnly:
                return .test([])
            case .unrulyModel:
                return .test([
                    ScriptedLabeler(.foundationModels) { request in
                        TopicShift(
                            isNewTopic: true, title: Self.unrulyTitle(for: request), summary: "A long summary. Two.")
                    }
                ])
            case .unrulyXAI:
                let generator = FakeTextGenerator { request in
                    let title = request.prompt.split(separator: "\n").last.map(String.init) ?? ""
                    let object: [String: Any] = ["isNewTopic": true, "title": "**" + title + "**", "summary": title]
                    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                }
                return .test([RemoteTopicLabeler(generator: generator)])
            }
        }

        /// The new topic's first user turn, verbatim and decorated: far more
        /// than five words.
        static func unrulyTitle(for request: TopicLabelRequest) -> String {
            "Title: \"" + (request.after.first?.userText ?? "") + "\""
        }
    }

    struct Fixture: Sendable {
        let name: String
        let units: [TopicUnit]
        let boundaries: [Int]
    }

    static let fixtures: [Fixture] =
        ScriptedTranscript.all.map { Fixture(name: $0.name, units: $0.units(), boundaries: $0.boundaries) }
        + (1...60).map { seed in
            let conversation = SyntheticConversation.generate(seed: UInt64(seed))
            return Fixture(name: "synthetic-\(seed)", units: conversation.units, boundaries: conversation.boundaries)
        }

    @Test(arguments: Setup.allCases)
    func everyLabelHasAtMostFiveWords(_ setup: Setup) async throws {
        var labels: [TopicLabel] = []
        for fixture in Self.fixtures {
            let service = setup.service()
            let (run, pipeline) = try await PipelineRun.run(fixture.units, service: service)
            labels += run.started.map(\.label)
            labels += run.candidates.compactMap(\.label)

            let starts = [0] + fixture.boundaries
            let ends = fixture.boundaries + [fixture.units.count]
            for (start, end) in zip(starts, ends) {
                let result = try #require(await pipeline.labelTopic(in: start..<end))
                labels.append(result.label)
            }
        }

        let tooLong = labels.filter { TopicTitleFormatter.wordCount($0.title) > TopicTitleFormatter.maximumWords }
        let empty = labels.filter { $0.title.allSatisfy(\.isWhitespace) }
        #expect(labels.count > 300, "only \(labels.count) labels")
        #expect(
            tooLong.isEmpty,
            "\(tooLong.count) of \(labels.count) titles are longer than five words: \(tooLong.prefix(5))")
        #expect(empty.isEmpty)
        #expect(labels.allSatisfy { $0.summary.isEmpty || ".!?…".contains($0.summary.last!) })
    }
}
