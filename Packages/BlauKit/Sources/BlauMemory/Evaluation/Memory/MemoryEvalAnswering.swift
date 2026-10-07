import Foundation

/// A text-in, text-out language model for the answer stage of the memory
/// evaluation: the reader that answers from retrieved memories and the
/// judge that grades the answer. `FoundationModelsEvalLanguageModel` (Apple's
/// on-device model) and `ChatCompletionsEvalLanguageModel` (Grok, or any
/// OpenAI-compatible endpoint) conform; tests pass fakes.
public protocol MemoryEvalLanguageModel: Sendable {
    /// Names the model in reports, e.g. `apple-foundation-models`.
    var identifier: String { get }
    /// One reply to `prompt` under `instructions`, from a fresh context
    /// (nothing carries over between calls). Deterministic decoding where
    /// the model offers it.
    func respond(instructions: String, prompt: String) async throws -> String
}

/// Answers a question from the memories retrieval found.
public protocol MemoryEvalReader: Sendable {
    var identifier: String { get }
    /// - Parameters:
    ///   - memories: The search results, best first.
    ///   - now: When the question is asked.
    func answer(_ question: String, memories: [MemorySearchResult], now: Date) async throws -> String
}

/// Grades an answer against the reference.
public protocol MemoryEvalJudge: Sendable {
    var identifier: String { get }
    func judge(_ question: MemoryEvalDataset.Question, response: String) async throws -> MemoryEvalVerdict
}

/// A judge's decision.
public struct MemoryEvalVerdict: Codable, Hashable, Sendable {
    /// `nil` when the judge's reply was neither yes nor no.
    public var correct: Bool?
    /// The judge's raw reply.
    public var reply: String

    public init(correct: Bool?, reply: String) {
        self.correct = correct
        self.reply = reply
    }

    /// Reads a yes / no reply: the first word decides ("Yes.", "**No**",
    /// "yes, because…"). Anything else is `nil`.
    public static func parse(_ reply: String) -> MemoryEvalVerdict {
        let words = reply.lowercased().split { !$0.isLetter }
        let first = words.first.map(String.init)
        let correct: Bool? =
            switch first {
            case "yes", "correct": true
            case "no", "incorrect": false
            default: nil
            }
        return MemoryEvalVerdict(correct: correct, reply: reply)
    }
}

/// The reader: the retrieved memories, dated, in a prompt that asks for a
/// short answer from them alone, with "I don't know" when they don't hold
/// it. A stand-in for Grok reading `search_memory` results (#68): the same
/// snippets, the date each was said or written, and whether a fact has
/// since stopped being true.
public struct LLMMemoryEvalReader: MemoryEvalReader {
    public let model: any MemoryEvalLanguageModel
    /// What to call the user ("Jordan").
    public var userName: String
    public var timeZone: TimeZone

    public init(model: any MemoryEvalLanguageModel, userName: String, timeZone: TimeZone) {
        self.model = model
        self.userName = userName
        self.timeZone = timeZone
    }

    public var identifier: String { model.identifier }

    public var instructions: String {
        """
        You are Blau, a voice assistant with a long-term memory of your conversations with \(userName). \
        Answer \(userName)'s question using only the memories you are given. Each memory has the date it was said \
        or written. "User" in a memory means \(userName), and "Blau" is you. When memories disagree, the most \
        recent one is current. Work out dates and durations from the memories' dates and today's date. If the \
        memories don't contain the answer, say that you don't know; never guess. Answer in one or two short \
        sentences, without repeating the memories' numbers or headers.
        """
    }

    public func prompt(for question: String, memories: [MemorySearchResult], now: Date) -> String {
        var lines = ["Today is \(Self.day(now, in: timeZone)).", "", "Memories:"]
        if memories.isEmpty { lines.append("(none)") }
        for (index, memory) in memories.enumerated() {
            var header = "[\(index + 1)] \(Self.day(memory.date, in: timeZone)) · \(Self.label(memory.sourceKind))"
            if let until = Self.invalidation(of: memory.chunk) { header += " · no longer true since \(until)" }
            lines.append(header)
            lines.append(memory.snippet)
        }
        lines += ["", "Question: \(question)"]
        return lines.joined(separator: "\n")
    }

    public func answer(_ question: String, memories: [MemorySearchResult], now: Date) async throws -> String {
        try await model.respond(instructions: instructions, prompt: prompt(for: question, memories: memories, now: now))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Wednesday, October 7, 2026", in English whatever the locale.
    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        date.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone)
                .weekday(.wide).month(.wide).day().year())
    }

    static func label(_ kind: MemorySourceKind) -> String {
        switch kind {
        case .conversation: "conversation"
        case .document: "note or document"
        case .collectionItem: "practice question"
        case .fact: "fact"
        }
    }

    /// For an invalidated fact, the date in its key text's `(until …)`.
    static func invalidation(of chunk: MemoryChunk) -> String? {
        guard chunk.sourceKind == .fact, chunk.keyText.hasSuffix(")"),
            let range = chunk.keyText.range(of: " (until ", options: .backwards)
        else { return nil }
        return String(chunk.keyText[range.upperBound...].dropLast())
    }
}

/// The judge: LongMemEval's grading prompts (`evaluate_qa.py`, adapted),
/// one per question type, answered with yes or no.
public struct LLMMemoryEvalJudge: MemoryEvalJudge {
    public let model: any MemoryEvalLanguageModel

    public init(model: any MemoryEvalLanguageModel) {
        self.model = model
    }

    public var identifier: String { model.identifier }

    public static let instructions = "You grade answers. Reply with yes or no only."

    public static func prompt(for question: MemoryEvalDataset.Question, response: String) -> String {
        let base = """
            I will give you a question, a correct answer, and a response from a model. Please answer yes if the \
            response contains the correct answer. Otherwise, answer no. If the response is equivalent to the \
            correct answer or contains all the intermediate steps to get the correct answer, you should also \
            answer yes. If the response only contains a subset of the information required by the answer, \
            answer no. Extra details, dates or quotes in the response are fine as long as it contains the correct \
            answer and doesn't contradict it.
            """
        let rule: String
        switch question.type {
        case .singleFact, .multiHop:
            rule = base
        case .temporal:
            rule =
                base + " "
                    + """
                    In addition, do not penalize off-by-one errors for the number of days. If the question asks for \
                    the number of days, weeks or months and the model makes an off-by-one error (for example, \
                    predicting 19 days when the answer is 18), the response is still correct.
                    """
        case .knowledgeUpdate:
            rule =
                base + " "
                    + """
                    If the response contains some previous information along with an updated answer, the response \
                    should be considered correct as long as the updated answer is the required answer.
                    """
        case .abstention:
            return """
                I will give you an unanswerable question, an explanation, and a response from a model. Please \
                answer yes if the model correctly identifies the question as unanswerable. The model could say \
                that the information is incomplete, or that some other information is given but the asked \
                information is not.

                Question: \(question.question)

                Explanation: \(question.answer)

                Model Response: \(response)

                Does the model correctly identify the question as unanswerable? Answer yes or no only.
                """
        }
        return """
            \(rule)

            Question: \(question.question)

            Correct Answer: \(question.answer)

            Model Response: \(response)

            Is the model response correct? Answer yes or no only.
            """
    }

    public func judge(_ question: MemoryEvalDataset.Question, response: String) async throws -> MemoryEvalVerdict {
        let reply = try await model.respond(
            instructions: Self.instructions, prompt: Self.prompt(for: question, response: response))
        return MemoryEvalVerdict.parse(reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
