import BlauCore
import BlauTelemetry
import Foundation
import os

/// What the practice tools share: the clock, the user's time zone, the
/// output budget and the scheduler.
public struct PracticeToolSettings: Sendable {
    /// Timestamps attempts (`now`) and measures idle runs (`uptime`).
    public var clock: any BlauClock
    /// The user's time zone, for dates in outputs.
    public var timeZone: @Sendable () -> TimeZone
    /// The budget for one tool output, in approximate tokens (UTF-8 bytes /
    /// 4), like the memory tools.
    public var maximumOutputTokens: Int
    /// The longest reference answer an output carries, in characters.
    public var maximumAnswerCharacters: Int
    /// The longest prompt a listing carries, in characters.
    public var maximumPromptCharacters: Int
    /// The longest note kept per attempt, in characters.
    public var maximumNoteCharacters: Int
    /// Without a topic to follow (no conversation recorder), a run left
    /// alone this long is over, and the next question starts a new one.
    public var idleRunLifetime: Duration
    /// Picks the next prompt: least recently and worst practiced first.
    public var scheduler: PracticeScheduler

    public init(
        clock: any BlauClock = SystemClock(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        maximumOutputTokens: Int = 1_500,
        maximumAnswerCharacters: Int = 900,
        maximumPromptCharacters: Int = 240,
        maximumNoteCharacters: Int = 240,
        idleRunLifetime: Duration = .seconds(30 * 60),
        scheduler: PracticeScheduler = .standard
    ) {
        self.clock = clock
        self.timeZone = timeZone
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumAnswerCharacters = maximumAnswerCharacters
        self.maximumPromptCharacters = maximumPromptCharacters
        self.maximumNoteCharacters = maximumNoteCharacters
        self.idleRunLifetime = idleRunLifetime
        self.scheduler = scheduler
    }

    /// Whether `output` fits ``maximumOutputTokens``.
    func fits(_ output: String) -> Bool {
        MemoryToolSettings.approximateTokens(output) <= maximumOutputTokens
    }
}

/// Practice mode's state and logic (#69): which collection is being
/// drilled, which prompts this run has asked, their scores and notes, and
/// the run's topic. The four practice tools are thin wrappers around it.
///
/// **A run** starts with the first `next_practice_question` for a
/// collection: it opens a topic of its own (``PracticeRunRecording``,
/// the topic lifecycle in the app) starting with the user's request. Each
/// question comes from ``PracticeScheduler`` (least recently and worst
/// practiced first), never one already asked in the run. Each
/// `record_practice_result` writes the attempt to the collection item (the
/// synced practice record) and refreshes the topic's summary with every
/// score and note so far. `end_practice` closes the topic, and so does the
/// conversation ending. Asking for another collection ends the run and
/// starts a new one.
///
/// One coordinator serves the app's sessions: a run whose topic is no
/// longer open (the conversation finished), or, without a topic, one left
/// alone for ``PracticeToolSettings/idleRunLifetime``, is over.
public actor PracticeCoordinator {
    /// One prompt's outcome in the current run.
    public struct Attempt: Hashable, Sendable {
        public var itemID: UUID
        public var prompt: String
        public var score: Double?
        public var note: String?
    }

    /// The run in progress, for tests and the tools' outputs.
    public struct Run: Hashable, Sendable {
        public var collectionID: UUID
        public var title: String
        /// How many prompts the collection had when the run started.
        public var itemCount: Int
        /// The recorder's id for the run (its topic), if it took the run.
        public var recordingID: UUID?
        /// The prompts asked, in order.
        public var asked: [UUID] = []
        /// The prompts answered and recorded, in the order they were.
        public var attempts: [Attempt] = []
        /// The prompt of each asked item, for the summary.
        var prompts: [UUID: String] = [:]
        /// When the run was last used (uptime).
        var lastActivity: Duration

        /// The mean score of the scored attempts.
        public var averageScore: Double? {
            let scores = attempts.compactMap(\.score)
            return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        }
    }

    /// What `next_practice_question` returns.
    public struct NextQuestion: Sendable {
        public var collection: PracticeCollection
        /// `nil` when every prompt has been asked in this run.
        public var item: PracticeItem?
        /// 1-based position in the collection.
        public var number: Int?
        public var run: Run
        /// Whether this call started the run.
        public var startedRun: Bool
    }

    /// What `record_practice_result` returns.
    public struct Recorded: Sendable {
        public var item: PracticeItem
        public var previousScore: Double?
        /// The run, if the prompt belongs to it.
        public var run: Run?
    }

    public nonisolated let backend: any PracticeBackend
    public nonisolated let runs: any PracticeRunRecording
    public nonisolated let settings: PracticeToolSettings
    private var run: Run?

    public init(
        backend: any PracticeBackend, runs: any PracticeRunRecording = NoPracticeRunRecording(),
        settings: PracticeToolSettings = PracticeToolSettings()
    ) {
        self.backend = backend
        self.runs = runs
        self.settings = settings
    }

    /// The run in progress, if it is still live.
    public func currentRun() async -> Run? {
        guard let run, await isLive(run) else { return nil }
        return run
    }

    // MARK: Collections

    /// Every collection.
    public func collections() async throws -> [PracticeCollection] {
        let backend = backend
        return try await Self.run { try await backend.practiceCollections() }
    }

    /// The collection `name` means.
    ///
    /// - Throws: ``RealtimeToolError/failed(_:)`` naming the user's
    ///   collections when none matches (or there are none).
    public func collection(named name: String) async throws -> PracticeCollection {
        let all = try await collections()
        guard !all.isEmpty else {
            throw RealtimeToolError.failed(
                "The user has no collections to practice yet. They can add one, for example by pasting a list of "
                    + "questions, in Settings, Knowledge, Collections.")
        }
        guard let match = PracticeCollectionMatcher.best(name, in: all) else {
            let names = all.prefix(12).map { "\"\($0.title)\"" }.joined(separator: ", ")
            throw RealtimeToolError.failed(
                "No collection matches that name. The user's collections: \(names). Ask which one they mean.")
        }
        return match
    }

    /// The collection's prompts, in order.
    public func items(of collection: PracticeCollection) async throws -> [PracticeItem] {
        let backend = backend
        let id = collection.id
        return try await Self.run { try await backend.practiceItems(inCollection: id) }
    }

    // MARK: Questions

    /// The next prompt of the collection `name` means, starting a run (and
    /// its topic) unless one is going on for it.
    public func nextQuestion(collectionNamed name: String) async throws -> NextQuestion {
        let collection = try await collection(named: name)
        let items = try await items(of: collection)
        guard !items.isEmpty else {
            throw RealtimeToolError.failed(
                "\"\(collection.title)\" has no questions yet. The user can add some in Settings, Knowledge, "
                    + "Collections.")
        }
        var started = false
        if let current = run, current.collectionID == collection.id, await isLive(current) {
            // Carry on.
        } else {
            await endRun(reason: "a new run started")
            started = true
            let recordingID = await runs.beginPracticeRun(
                title: Self.topicTitle(collection.title), at: settings.clock.now)
            run = Run(
                collectionID: collection.id, title: collection.title, itemCount: items.count, recordingID: recordingID,
                lastActivity: settings.clock.uptime)
            Log.realtime.notice(
                "Practice run started over \(items.count, privacy: .public) prompts (topic: \(recordingID != nil, privacy: .public))"
            )
        }
        if !started, let current = run, current.recordingID == nil {
            // The recorder had no conversation when the run started (it was
            // still opening): give the run its topic from here on.
            let recordingID = await runs.beginPracticeRun(
                title: Self.topicTitle(collection.title), at: settings.clock.now)
            if run?.collectionID == current.collectionID, run?.recordingID == nil {
                run?.recordingID = recordingID
            }
        }
        // From here to `run = current` nothing suspends, so a call running
        // alongside (record_practice_result in the same reply) can't be lost.
        guard var current = run else { throw RealtimeToolError.failed("The practice run couldn't start.") }
        current.lastActivity = settings.clock.uptime
        current.itemCount = items.count
        let next = settings.scheduler.next(in: items, at: settings.clock.now, excluding: Set(current.asked))
        if let next {
            current.asked.append(next.id)
            current.prompts[next.id] = next.prompt
        }
        run = current
        let number = next.flatMap { item in items.firstIndex { $0.id == item.id } }.map { $0 + 1 }
        return NextQuestion(collection: collection, item: next, number: number, run: current, startedRun: started)
    }

    // MARK: Results

    /// Records an attempt at the prompt `itemID` names: its id, or its
    /// 1-based number in the current run's collection.
    public func record(item reference: String, score: Double?, note: String?) async throws -> Recorded {
        let itemID = try await resolveItem(reference)
        let previous = try await previousScore(of: itemID)
        guard
            let item = try await Self.run({ [backend, now = settings.clock.now] in
                try await backend.recordPractice(itemID: itemID, score: score, at: now)
            })
        else {
            throw RealtimeToolError.failed("No question has that id. Use the id next_practice_question returned.")
        }
        guard let snapshot = run, snapshot.collectionID == item.collectionID, await isLive(snapshot) else {
            return Recorded(item: item, previousScore: previous, run: nil)
        }
        // Read again after the suspension: next_practice_question may have
        // run alongside. Nothing suspends from here to `run = current`.
        guard var current = run, current.collectionID == item.collectionID else {
            return Recorded(item: item, previousScore: previous, run: nil)
        }
        let note = note.map { MemoryToolText.clipped($0, to: settings.maximumNoteCharacters) }.flatMap(\.nonBlank)
        let attempt = Attempt(itemID: item.id, prompt: item.prompt, score: score, note: note)
        if let index = current.attempts.firstIndex(where: { $0.itemID == item.id }) {
            current.attempts[index] = attempt
        } else {
            current.attempts.append(attempt)
        }
        if !current.asked.contains(item.id) {
            current.asked.append(item.id)
        }
        current.prompts[item.id] = item.prompt
        current.lastActivity = settings.clock.uptime
        run = current
        if let recordingID = current.recordingID {
            await runs.updatePracticeRun(recordingID, summary: Self.summary(of: current))
        }
        return Recorded(item: item, previousScore: previous, run: current)
    }

    /// Ends the run in progress, closing its topic. Returns it, or `nil` if
    /// none was going on.
    @discardableResult
    public func endRun() async -> Run? {
        guard let current = run, await isLive(current) else {
            run = nil
            return nil
        }
        await endRun(reason: "ended")
        return current
    }

    // MARK: Helpers

    private func endRun(reason: String) async {
        guard let current = run else { return }
        run = nil
        if let recordingID = current.recordingID, await runs.isPracticeRunOpen(recordingID) {
            await runs.updatePracticeRun(recordingID, summary: Self.summary(of: current))
            await runs.endPracticeRun(recordingID, at: settings.clock.now)
        }
        Log.realtime.notice(
            "Practice run \(reason, privacy: .public) after \(current.attempts.count, privacy: .public) of \(current.asked.count, privacy: .public) asked prompts"
        )
    }

    private func isLive(_ run: Run) async -> Bool {
        if let recordingID = run.recordingID {
            return await runs.isPracticeRunOpen(recordingID)
        }
        return settings.clock.uptime - run.lastActivity < settings.idleRunLifetime
    }

    /// An item id, or a question number of the current run's collection.
    private func resolveItem(_ reference: String) async throws -> UUID {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text) { return id }
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let number = Int(digits), let current = run {
            let collectionID = current.collectionID
            let items = try await Self.run { [backend] in try await backend.practiceItems(inCollection: collectionID) }
            if items.indices.contains(number - 1) { return items[number - 1].id }
        }
        throw RealtimeToolError.invalidArguments("item_id must be the id next_practice_question returned")
    }

    private func previousScore(of itemID: UUID) async throws -> Double? {
        guard let current = run else { return nil }
        let items = try? await backend.practiceItems(inCollection: current.collectionID)
        return items?.first { $0.id == itemID }?.score
    }

    /// Runs a backend call, turning its failures into ones the model sees.
    private static func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as MemoryToolFailure {
            throw RealtimeToolError.failed(failure.description)
        }
    }

    /// The run's topic title: "Practice: YC interview questions".
    public static func topicTitle(_ collectionTitle: String) -> String {
        "Practice: \(collectionTitle)"
    }

    /// The run's topic summary: a headline, then one line per answered
    /// prompt with its score and note, in the order they were answered.
    public static func summary(of run: Run) -> String {
        var headline = "Practiced \(run.attempts.count) of \(run.itemCount) questions in \(run.title)"
        if let average = run.averageScore {
            headline += ", average \(percent(average))"
        }
        headline += "."
        let lines = run.attempts.map { attempt in
            var line = "- \(attempt.prompt) \(attempt.score.map(percent) ?? "not scored")"
            if let note = attempt.note {
                line += ". \(note)"
            }
            return line
        }
        return ([headline] + lines).joined(separator: "\n")
    }

    /// "72%".
    static func percent(_ score: Double) -> String {
        "\(Int((min(max(score, 0), 1) * 100).rounded()))%"
    }
}
