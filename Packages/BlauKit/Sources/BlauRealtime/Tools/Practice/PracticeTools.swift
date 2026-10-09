import BlauCore
import Foundation

/// Grok's practice tools (#69): `list_collection`, `next_practice_question`,
/// `record_practice_result` and `end_practice`, over one
/// ``PracticeCoordinator``.
///
/// ```swift
/// var registry = RealtimeToolRegistry()
/// try registry.register(contentsOf: PracticeTools.all(coordinator: PracticeCoordinator(backend: store, runs: topics)))
/// ```
///
/// The instructions' Practice section (``RealtimeInstructions``) teaches
/// Grok to act as the interviewer; each tool's description repeats the
/// essentials. Outputs stay under ``PracticeToolSettings/maximumOutputTokens``.
public enum PracticeTools {
    public static let listCollection = ListCollectionTool.name
    public static let nextPracticeQuestion = NextPracticeQuestionTool.name
    public static let recordPracticeResult = RecordPracticeResultTool.name
    public static let endPractice = EndPracticeTool.name

    /// Every practice tool's name.
    public static let names: [String] = [listCollection, nextPracticeQuestion, recordPracticeResult, endPractice]

    /// The four tools, sharing `coordinator` (one run at a time).
    public static func all(coordinator: PracticeCoordinator) -> [any RealtimeFunctionTool] {
        [
            ListCollectionTool(coordinator: coordinator),
            NextPracticeQuestionTool(coordinator: coordinator),
            RecordPracticeResultTool(coordinator: coordinator),
            EndPracticeTool(coordinator: coordinator),
        ]
    }

    /// What the user says (as text) when they start practice from the app's
    /// Collections screen, so Grok switches modes the same way as when they
    /// ask out loud.
    public static func startRequest(collectionTitle: String) -> String {
        "Let's practice my \"\(collectionTitle)\" collection. Ask me the questions one at a time."
    }
}

// MARK: - list_collection

/// `list_collection(name?)`: the user's collections, or one collection's
/// questions with their practice record (#69).
public struct ListCollectionTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var name: String?

        public init(name: String? = nil) {
            self.name = name
        }
    }

    public static let name = "list_collection"
    public static let description = """
        List the user's collections of practice questions (such as YC interview questions), or, given a \
        collection's name, its questions in order with how often and how well each was practiced. Use it to find \
        which collection the user means or to tell them how their practice is going.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "name": .string(
                description:
                    "The collection's name, e.g. \"YC interview questions\". Leave it out to list every collection.")
        ],
        additionalProperties: false)
    public static let timeout: Duration = .seconds(5)

    public let coordinator: PracticeCoordinator

    public init(coordinator: PracticeCoordinator) {
        self.coordinator = coordinator
    }

    public func call(arguments: Arguments) async throws -> String {
        let settings = coordinator.settings
        let timeZone = settings.timeZone()
        guard let name = arguments.name?.nonBlank else {
            let collections = try await coordinator.collections()
            var output = CollectionsOutput(
                collections: collections.map { PracticeCollectionOutput($0, timeZone: timeZone) })
            if collections.isEmpty {
                output.message =
                    "The user has no collections yet. They can add one in Settings, Knowledge, Collections."
            }
            while !settings.fits(try RealtimeToolOutput.json(output)), !output.collections.isEmpty {
                output.collections.removeLast()
                output.omitted = (output.omitted ?? 0) + 1
            }
            return try RealtimeToolOutput.json(output)
        }
        let collection = try await coordinator.collection(named: name)
        let items = try await coordinator.items(of: collection)
        var output = ItemsOutput(collection: PracticeCollectionOutput(collection, timeZone: timeZone), questions: [])
        for (index, item) in items.enumerated() {
            output.questions.append(
                PracticeItemOutput(
                    item, number: index + 1, timeZone: timeZone, promptLimit: settings.maximumPromptCharacters))
            if !settings.fits(try RealtimeToolOutput.json(output)) {
                output.questions.removeLast()
                output.omitted = items.count - index
                break
            }
        }
        return try RealtimeToolOutput.json(output)
    }

    struct CollectionsOutput: Encodable {
        var collections: [PracticeCollectionOutput]
        var omitted: Int?
        var message: String?
    }

    struct ItemsOutput: Encodable {
        var collection: PracticeCollectionOutput
        var questions: [PracticeItemOutput]
        var omitted: Int?
    }
}

// MARK: - next_practice_question

/// `next_practice_question(collection)`: the next question to ask, least
/// recently and worst practiced first; starts a practice run (a topic of
/// its own) unless one is going on for that collection (#69).
public struct NextPracticeQuestionTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var collection: String

        public init(collection: String) {
            self.collection = collection
        }
    }

    public static let name = "next_practice_question"
    public static let description = """
        Start or continue practicing a collection: returns the next question to ask, least recently and worst \
        practiced first, never one already asked in this run, with its reference answer. Ask the question as \
        written and listen. The first call starts a practice run.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "collection": .string(description: "The collection's name, e.g. \"YC interview questions\".")
        ],
        required: ["collection"],
        additionalProperties: false)
    public static let timeout: Duration = .seconds(5)

    public let coordinator: PracticeCoordinator

    public init(coordinator: PracticeCoordinator) {
        self.coordinator = coordinator
    }

    public func call(arguments: Arguments) async throws -> String {
        let name = arguments.collection.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = try await coordinator.nextQuestion(collectionNamed: name)
        let settings = coordinator.settings
        let timeZone = settings.timeZone()
        let run = RunOutput(next.run)
        guard let item = next.item, let number = next.number else {
            return try RealtimeToolOutput.json(
                Output(
                    collection: next.collection.title, started: next.startedRun ? true : nil, run: run, done: true,
                    instruction: """
                        Every question in this collection has been asked in this run. Call end_practice and give \
                        the user a short summary.
                        """))
        }
        var question = PracticeItemOutput(
            item, number: number, timeZone: timeZone, promptLimit: settings.maximumAnswerCharacters)
        question.referenceAnswer = item.referenceAnswer.map {
            MemoryToolText.clipped($0, to: settings.maximumAnswerCharacters)
        }
        var output = Output(
            collection: next.collection.title, started: next.startedRun ? true : nil, run: run, question: question,
            instruction: """
                Ask this question as written, then stop and listen. Don't read the reference answer aloud. After \
                the answer, give brief feedback and call record_practice_result.
                """)
        if !settings.fits(try RealtimeToolOutput.json(output)) {
            output.question?.referenceAnswer = question.referenceAnswer.map { MemoryToolText.clipped($0, to: 300) }
        }
        return try RealtimeToolOutput.json(output)
    }

    struct Output: Encodable {
        var collection: String
        var started: Bool?
        var run: RunOutput
        var question: PracticeItemOutput?
        var done: Bool?
        var instruction: String
    }
}

// MARK: - record_practice_result

/// `record_practice_result(item_id, score, notes?)`: stores how the user
/// did on one question, in the synced practice record, and adds it to the
/// run's summary (#69).
public struct RecordPracticeResultTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var itemID: String
        public var score: Double?
        public var notes: String?

        public init(itemID: String, score: Double?, notes: String? = nil) {
            self.itemID = itemID
            self.score = score
            self.notes = notes
        }

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case score, notes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Models sometimes send the id as a number (a question number).
            if let text = try? container.decode(String.self, forKey: .itemID) {
                itemID = text
            } else {
                itemID = String(try container.decode(Int.self, forKey: .itemID))
            }
            if let number = try? container.decodeIfPresent(Double.self, forKey: .score) {
                score = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .score) {
                score = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
            } else {
                score = nil
            }
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
        }
    }

    public static let name = "record_practice_result"
    public static let description = """
        Record how the user did on a practice question, after you gave feedback. Score from 0 to 1: 1 is as \
        strong as the reference answer (or a strong answer when there is none), 0.5 partly there, 0 missed or \
        skipped. Add a one-line note on what to improve. Then call next_practice_question for the next one.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "item_id": .string(description: "The question's id from next_practice_question."),
            "score": .number(description: "How good the answer was, from 0 to 1.", minimum: 0, maximum: 1),
            "notes": .string(description: "One short line: what worked and what to improve."),
        ],
        required: ["item_id", "score"],
        additionalProperties: false)
    public static let timeout: Duration = .seconds(5)

    public let coordinator: PracticeCoordinator

    public init(coordinator: PracticeCoordinator) {
        self.coordinator = coordinator
    }

    public func call(arguments: Arguments) async throws -> String {
        let score = try arguments.score.map(Self.normalizedScore)
        let recorded = try await coordinator.record(
            item: arguments.itemID, score: score, note: arguments.notes?.nonBlank)
        return try RealtimeToolOutput.json(
            Output(
                recorded: .init(
                    id: recorded.item.id.uuidString,
                    prompt: MemoryToolText.clipped(recorded.item.prompt, to: 160),
                    score: score.map(PracticeOutputNumber.rounded),
                    previousScore: recorded.previousScore.map(PracticeOutputNumber.rounded),
                    timesPracticed: recorded.item.practiceCount),
                run: recorded.run.map(RunOutput.init)))
    }

    /// A score in `0...1`. Models sometimes answer on a 10- or 100-point
    /// scale; those are scaled down. Anything else is rejected.
    static func normalizedScore(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw RealtimeToolError.invalidArguments("score must be a number from 0 to 1")
        }
        if value <= 1 { return value }
        if value <= 10 { return value / 10 }
        if value <= 100 { return value / 100 }
        throw RealtimeToolError.invalidArguments("score must be a number from 0 to 1")
    }

    struct Output: Encodable {
        struct Recorded: Encodable {
            var id: String
            var prompt: String
            var score: Double?
            var previousScore: Double?
            var timesPracticed: Int

            enum CodingKeys: String, CodingKey {
                case id, prompt, score
                case previousScore = "previous_score"
                case timesPracticed = "times_practiced"
            }
        }

        var recorded: Recorded
        var run: RunOutput?
    }
}

// MARK: - end_practice

/// `end_practice()`: ends the practice run, closing its topic, and returns
/// what to sum up (#69).
public struct EndPracticeTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public init() {}
    }

    public static let name = "end_practice"
    public static let description = """
        End the practice run when the user wants to stop or every question was asked. Returns how many were \
        answered, the average score and the weakest answers, for a short spoken summary.
        """
    public static let parameters: JSONSchema = .object(properties: [:], additionalProperties: false)

    public let coordinator: PracticeCoordinator

    public init(coordinator: PracticeCoordinator) {
        self.coordinator = coordinator
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let run = await coordinator.endRun() else {
            return try RealtimeToolOutput.json(Output(message: "No practice run is going on."))
        }
        let weakest = run.attempts.filter { ($0.score ?? 0) < 0.7 }
            .sorted { ($0.score ?? 0) < ($1.score ?? 0) }
            .prefix(3)
            .map { Output.Attempt(prompt: MemoryToolText.clipped($0.prompt, to: 160), score: $0.score, note: $0.note) }
        let strongest = run.attempts.filter { ($0.score ?? 0) >= 0.8 }
            .max { ($0.score ?? 0) < ($1.score ?? 0) }
            .map { Output.Attempt(prompt: MemoryToolText.clipped($0.prompt, to: 160), score: $0.score, note: nil) }
        return try RealtimeToolOutput.json(
            Output(
                ended: .init(
                    collection: run.title, asked: run.asked.count, answered: run.attempts.count,
                    averageScore: run.averageScore.map(PracticeOutputNumber.rounded),
                    toWorkOn: weakest.isEmpty ? nil : Array(weakest), strongest: strongest)))
    }

    struct Output: Encodable {
        struct Attempt: Encodable {
            var prompt: String
            var score: Double?
            var note: String?

            init(prompt: String, score: Double?, note: String?) {
                self.prompt = prompt
                self.score = score.map(PracticeOutputNumber.rounded)
                self.note = note
            }
        }

        struct Ended: Encodable {
            var collection: String
            var asked: Int
            var answered: Int
            var averageScore: Double?
            var toWorkOn: [Attempt]?
            var strongest: Attempt?

            enum CodingKeys: String, CodingKey {
                case collection, asked, answered, strongest
                case averageScore = "average_score"
                case toWorkOn = "to_work_on"
            }
        }

        var ended: Ended?
        var message: String?
    }
}

// MARK: - Shared output

/// A collection as the practice tools show it.
struct PracticeCollectionOutput: Encodable, Hashable {
    var name: String
    var questions: Int
    var practiced: Int
    var averageScore: Double?
    var lastPracticed: String?

    init(_ collection: PracticeCollection, timeZone: TimeZone) {
        name = collection.title
        questions = collection.itemCount
        practiced = collection.practicedCount
        averageScore = collection.averageScore.map(PracticeOutputNumber.rounded)
        lastPracticed = collection.lastPracticedAt.map { MemoryToolText.day($0, timeZone: timeZone) }
    }

    enum CodingKeys: String, CodingKey {
        case name, questions, practiced
        case averageScore = "average_score"
        case lastPracticed = "last_practiced"
    }
}

/// A question as the practice tools show it.
struct PracticeItemOutput: Encodable, Hashable {
    var id: String
    var number: Int
    var prompt: String
    var referenceAnswer: String?
    var hasReferenceAnswer: Bool?
    var timesPracticed: Int
    var lastScore: Double?
    var lastPracticed: String?

    init(_ item: PracticeItem, number: Int, timeZone: TimeZone, promptLimit: Int) {
        id = item.id.uuidString
        self.number = number
        prompt = MemoryToolText.clipped(item.prompt, to: promptLimit)
        hasReferenceAnswer = item.referenceAnswer?.nonBlank != nil ? true : nil
        timesPracticed = item.practiceCount
        lastScore = item.score.map(PracticeOutputNumber.rounded)
        lastPracticed = item.lastPracticedAt.map { MemoryToolText.day($0, timeZone: timeZone) }
    }

    enum CodingKeys: String, CodingKey {
        case id, number, prompt
        case referenceAnswer = "reference_answer"
        case hasReferenceAnswer = "has_reference_answer"
        case timesPracticed = "times_practiced"
        case lastScore = "last_score"
        case lastPracticed = "last_practiced"
    }
}

/// Where the run stands.
struct RunOutput: Encodable, Hashable {
    var asked: Int
    var answered: Int
    var total: Int
    var averageScore: Double?

    init(_ run: PracticeCoordinator.Run) {
        asked = run.asked.count
        answered = run.attempts.count
        total = run.itemCount
        averageScore = run.averageScore.map(PracticeOutputNumber.rounded)
    }

    enum CodingKeys: String, CodingKey {
        case asked, answered, total
        case averageScore = "average_score"
    }
}

enum PracticeOutputNumber {
    /// Two decimals, so outputs stay short and stable.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
