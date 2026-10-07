import BlauCore
import BlauPersistence
import BlauTelemetry
import Darwin
import Foundation
import SwiftData
import Testing

/// Stress tests for the pipeline write path: 10,000 utterances through
/// `ConversationStore` into an on-disk (SQLite) store, timed against a
/// budget. Each run prints a `DBSTRESS` line; the baselines are recorded in
/// docs/performance.md.
///
/// The budget is checked against the process's CPU time rather than wall
/// time, so a busy host (parallel builds, other test suites) doesn't make
/// the test flaky, and it is loose enough to only catch large regressions
/// such as an extra save per utterance. Override it with
/// `BLAU_DB_STRESS_BUDGET_MS`. The worst-case and comparison runs are slow
/// and only run with `BLAU_DB_STRESS=1`.
@Suite("ConversationStore stress", .serialized)
struct ConversationStoreStressTests {
    static let utteranceCount = 10_000

    /// CPU budget for 10,000 utterances (debug build, macOS host).
    static var budget: Duration {
        let override = ProcessInfo.processInfo.environment["BLAU_DB_STRESS_BUDGET_MS"].flatMap(Int.init)
        return .milliseconds(override ?? 15_000)
    }

    static let extendedRunsEnabled = ProcessInfo.processInfo.environment["BLAU_DB_STRESS"] == "1"

    /// The realistic shape: 10 conversations of 1,000 utterances (a long
    /// session is 1,000 to 2,000), alternating user and agent, with a topic
    /// change every 100 utterances. Saves are coalesced.
    @Test func tenThousandUtterancesAcrossConversationsWithinBudget() async throws {
        try await withTemporaryStore { container in
            let result = try await StressRun.run(
                container: container, policy: .coalesced, conversations: 10, utterancesPerConversation: 1_000)
            result.report("10 x 1,000, coalesced")

            let context = ModelContext(container)
            #expect(try context.fetchCount(FetchDescriptor<StoredUtterance>()) == Self.utteranceCount)
            #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 10)
            #expect(try context.fetchCount(FetchDescriptor<Topic>()) == 100)
            #expect(result.statistics.mainThreadSaveCount == 0)
            #expect(result.statistics.failedSaveCount == 0)
            #expect(result.cpu < Self.budget, "Used \(result.cpu) of CPU, budget \(Self.budget)")
        }
    }

    /// The worst case: one conversation with 10,000 utterances. SwiftData
    /// updates the inverse to-many (`Conversation.utterances`) on every link,
    /// so the cost per utterance grows with the conversation's size.
    @Test(.enabled(if: extendedRunsEnabled))
    func tenThousandUtterancesInOneConversation() async throws {
        try await withTemporaryStore { container in
            let result = try await StressRun.run(
                container: container, policy: .coalesced, conversations: 1, utterancesPerConversation: 10_000)
            result.report("1 x 10,000, coalesced")
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredUtterance>()) == 10_000)
            #expect(result.statistics.mainThreadSaveCount == 0)
        }
    }

    /// For comparison: one save per change. Shows what coalescing saves.
    @Test(.enabled(if: extendedRunsEnabled))
    func saveEveryChangeComparison() async throws {
        try await withTemporaryStore { container in
            let result = try await StressRun.run(
                container: container, policy: .immediate, conversations: 1, utterancesPerConversation: 500)
            result.report("1 x 500, immediate")
            #expect(result.statistics.saveCount >= 500)
            #expect(result.statistics.mainThreadSaveCount == 0)
        }
    }

    private func withTemporaryStore(_ body: (ModelContainer) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-db-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(try BlauModelContainer.makeLocal(url: directory.appendingPathComponent("Blau.store")))
    }
}

/// One timed stress run.
struct StressRun {
    let label: String
    let utterances: Int
    let wall: Duration
    let cpu: Duration
    let statistics: ConversationStoreStatistics

    /// Commits `conversations x utterancesPerConversation` utterances through
    /// one store, opening a topic every 100, ending each conversation, and
    /// times everything from the first `startConversation` to the last save.
    static func run(
        container: ModelContainer,
        policy: ConversationStoreSavePolicy,
        conversations: Int,
        utterancesPerConversation: Int
    ) async throws -> StressRun {
        let store = ConversationStore(
            modelContainer: container,
            savePolicy: policy,
            clock: SystemClock(),
            signposter: .disabled(.data)
        )
        let plan = (0..<conversations).map { _ in
            let id = ConversationID()
            let utterances = (0..<utterancesPerConversation).map { index in
                makeUtterance(
                    "Utterance \(index): a sentence or two of transcript, about as long as people speak in one turn.",
                    in: id,
                    at: Double(index) * 3,
                    speaker: index.isMultiple(of: 2) ? .user : .agent
                )
            }
            return (id, utterances)
        }

        let clock = ContinuousClock()
        let wallStart = clock.now
        let cpuStart = processCPUTime()
        for (id, utterances) in plan {
            try await store.startConversation(id: id, at: storeT0)
            for (index, utterance) in utterances.enumerated() {
                if index.isMultiple(of: 100) {
                    try await store.openTopic(at: utterance.startedAt)
                }
                try await store.commitUtterance(utterance)
            }
            try await store.endConversation(at: storeT0 + Double(utterancesPerConversation) * 3)
        }
        let cpu = processCPUTime() - cpuStart
        let wall = wallStart.duration(to: clock.now)
        return StressRun(
            label: "",
            utterances: conversations * utterancesPerConversation,
            wall: wall,
            cpu: cpu,
            statistics: await store.statistics
        )
    }

    func report(_ label: String) {
        func ms(_ duration: Duration) -> String { String(format: "%.0f", duration.timeInterval * 1000) }
        let perUtterance = cpu.timeInterval * 1_000_000 / Double(utterances)
        print(
            "DBSTRESS \(label): \(utterances) utterances, cpu \(ms(cpu)) ms "
                + "(\(String(format: "%.0f", perUtterance)) µs each), wall \(ms(wall)) ms, "
                + "\(statistics.saveCount) saves"
        )
    }
}

/// User plus system CPU time of this process so far.
func processCPUTime() -> Duration {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func duration(_ time: timeval) -> Duration {
        .seconds(Int64(time.tv_sec)) + .microseconds(Int64(time.tv_usec))
    }
    return duration(usage.ru_utime) + duration(usage.ru_stime)
}
