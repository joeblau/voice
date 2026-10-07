import Foundation
import FoundationModels

/// Confirms and titles a candidate topic boundary with the on-device
/// Foundation Models language model, using guided generation
/// (`@Generable`) so the answer is always structured.
///
/// Each request uses a new `LanguageModelSession`: boundaries are
/// independent, and a reused session would carry earlier windows in its
/// context (4,096 tokens).
public struct FoundationModelsTopicLabeler: TopicLabelGenerator {
    public init() {}

    static let instructions = """
        You label topics in a spoken conversation. You get the exchanges before and after a possible topic \
        boundary. Decide whether the exchanges after the boundary start a new topic, and give the topic \
        after the boundary a title of at most five words.
        """

    public func unavailableReason() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "device not eligible"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .modelNotReady: return "the model is not ready (still downloading)"
            @unknown default: return "unavailable (\(reason))"
            }
        @unknown default:
            return "unknown availability"
        }
    }

    public func label(_ window: TopicBoundaryWindow, prewarm: Bool) async throws -> TopicLabelDraft {
        let session = LanguageModelSession(instructions: Self.instructions)
        if prewarm {
            session.prewarm()
        }
        let response = try await session.respond(
            to: Self.prompt(for: window),
            generating: GeneratedTopicLabel.self,
            options: GenerationOptions(temperature: 0)
        )
        return TopicLabelDraft(isNewTopic: response.content.isNewTopic, title: response.content.title)
    }

    static func prompt(for window: TopicBoundaryWindow) -> String {
        """
        Before the boundary:
        \(window.before.map { "- \($0)" }.joined(separator: "\n"))

        After the boundary:
        \(window.after.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}

@Generable
struct GeneratedTopicLabel {
    @Guide(description: "Whether the exchanges after the boundary start a new topic")
    var isNewTopic: Bool

    @Guide(description: "A title for the topic after the boundary, at most five words, no punctuation")
    var title: String
}
