import BlauCore
import BlauTelemetry
import BlauTopics
import Foundation
import Synchronization
import Testing

@Suite("Topic label benchmark")
struct TopicLabelBenchmarkTests {
    /// Virtual time: `sleep(for:)` returns at once after moving the clock
    /// forward, and the fakes `advance` it to simulate work.
    final class SteppingClock: BlauClock {
        private let state = Mutex<Duration>(.zero)

        var now: Date { Date(timeIntervalSinceReferenceDate: uptime.timeInterval) }
        var uptime: Duration { state.withLock { $0 } }

        func advance(by duration: Duration) { state.withLock { $0 += duration } }

        func sleep(for duration: Duration) async throws {
            try Task.checkCancellation()
            advance(by: duration)
        }
    }

    /// Cold first request 1.2 s, then 300 ms, or 200 ms when the session
    /// was prewarmed at least `prewarmTakes` before the request (a prewarm
    /// that hasn't finished doesn't help).
    final class FakeGenerator: TopicLabelGenerator {
        struct Request: Hashable {
            var prewarm: Bool
            var createdAt: Duration
            var startedAt: Duration?
        }

        let clock: SteppingClock
        let unavailable: String?
        let prewarmTakes: Duration
        let requests = Mutex<[Request]>([])

        init(clock: SteppingClock, unavailable: String? = nil, prewarmTakes: Duration = .seconds(1)) {
            self.clock = clock
            self.unavailable = unavailable
            self.prewarmTakes = prewarmTakes
        }

        func unavailableReason() async -> String? { unavailable }

        func makeSession(prewarm: Bool) async -> any TopicLabelSession {
            let index = requests.withLock { requests in
                requests.append(Request(prewarm: prewarm, createdAt: clock.uptime))
                return requests.count - 1
            }
            return Session(generator: self, index: index)
        }

        struct Session: TopicLabelSession {
            let generator: FakeGenerator
            let index: Int

            func label(_ window: TopicBoundaryWindow) async throws -> TopicLabelDraft {
                let clock = generator.clock
                let request = generator.requests.withLock { requests in
                    requests[index].startedAt = clock.uptime
                    return requests[index]
                }
                let warm = request.prewarm && clock.uptime - request.createdAt >= generator.prewarmTakes
                let cost: Duration = warm ? .milliseconds(200) : .milliseconds(300)
                clock.advance(by: index == 0 ? .milliseconds(1_200) : cost)
                // Every third title is too long.
                return TopicLabelDraft(
                    isNewTopic: true, title: (index + 1) % 3 == 0 ? "A title that is far too long" : "Weekend plans")
            }
        }
    }

    struct FixedProbe: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 1 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    @Test func measuresColdPlainAndPrewarmedRequests() async throws {
        let clock = SteppingClock()
        let generator = FakeGenerator(clock: clock)
        let benchmark = TopicLabelBenchmark(
            generator: generator, configuration: .init(iterations: 4, prewarmLead: .seconds(1.5)),
            signposter: .disabled(.topics))

        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(benchmark)

        #expect(result.outcome == .completed)
        #expect(result.id == "topics.label.foundationModels")
        #expect(result.metric("label.cold")?.value == 1_200)
        #expect(result.latencies["label"]?.count == 4)
        #expect(result.latencies["label"]?.p50 == 300)
        #expect(result.latencies["label.prewarmed"]?.p50 == 200)
        // 9 requests, titles 3, 6 and 9 too long.
        #expect(abs((result.metric("titles.withinWordLimit")?.value ?? 0) - 600.0 / 9) < 1e-9)
        let requests = generator.requests.withLock { $0 }
        #expect(requests.map(\.prewarm) == [false, false, true, false, true, false, true, false, true])
        // Every timed request after the cold one starts a full lead after its
        // session was created (and prewarmed), so the prewarm runs outside
        // the timed interval and has time to finish.
        for request in requests.dropFirst() {
            let startedAt = try #require(request.startedAt)
            #expect(startedAt - request.createdAt == .seconds(1.5))
        }
    }

    @Test func aLeadShorterThanThePrewarmShowsNoBenefit() async throws {
        // Guards the method: with no lead, prewarming can't help, which is
        // what the first Mac run measured by mistake.
        let clock = SteppingClock()
        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(
                TopicLabelBenchmark(
                    generator: FakeGenerator(clock: clock), configuration: .init(iterations: 2, prewarmLead: .zero),
                    signposter: .disabled(.topics)))
        #expect(result.latencies["label.prewarmed"]?.p50 == 300)
    }

    @Test func skipsWhenTheModelIsUnavailable() async {
        let clock = SteppingClock()
        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(
                TopicLabelBenchmark(
                    generator: FakeGenerator(clock: clock, unavailable: "Apple Intelligence is turned off")))
        #expect(result.outcome == .skipped(reason: "Foundation Models unavailable: Apple Intelligence is turned off"))
    }

    @Test func countsTitleWords() {
        #expect(TopicLabelDraft(isNewTopic: true, title: "  Launch  plan ").titleWordCount == 2)
        #expect(TopicLabelDraft(isNewTopic: false, title: "").titleWordCount == 0)
    }

    @Test func fixtureWindowsHaveTextOnBothSides() {
        #expect(TopicBoundaryWindow.benchmarkWindows.count >= 4)
        for window in TopicBoundaryWindow.benchmarkWindows {
            #expect(!window.before.isEmpty && !window.after.isEmpty)
        }
    }
}
