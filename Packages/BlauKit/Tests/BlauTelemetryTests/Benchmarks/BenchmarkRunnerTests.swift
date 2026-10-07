import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@Suite("Benchmark runner")
struct BenchmarkRunnerTests {
    /// A case whose "work" advances the manual clock.
    struct ScriptedCase: BenchmarkCase {
        var id = "test.scripted"
        var title = "Scripted"
        var category: LogCategory { .asr }
        let clock: ManualClock
        var failure: (any Error & Sendable)?

        func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
            let (_, load) = context.measure { clock.advance(by: .milliseconds(120)) }
            recorder.record("load", load)
            var samples: [Duration] = []
            for step in 1...4 {
                let (_, elapsed) = context.measure { clock.advance(by: .milliseconds(10 * step)) }
                samples.append(elapsed)
                recorder.progress(Double(step) / 4, "step \(step)")
            }
            recorder.recordLatencies("chunk", samples)
            recorder.note("scripted")
            if let failure { throw failure }
            recorder.record("rtfx", 12.5, unit: .realTimeFactor)
        }
    }

    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    static func context(_ clock: ManualClock, thermal: [ThermalState] = [.nominal]) -> BenchmarkContext {
        let states = Mutex(thermal)
        return BenchmarkContext(clock: clock, memory: ScriptedMemoryProbe()) {
            states.withLock { states in states.count > 1 ? states.removeFirst() : states[0] }
        }
    }

    @Test func completedCaseCarriesItsMeasurements() async throws {
        let clock = ManualClock()
        let progress = Mutex<[BenchmarkProgress]>([])
        let runner = BenchmarkRunner(context: Self.context(clock)) { update in progress.withLock { $0.append(update) } }

        let result = await runner.run(ScriptedCase(clock: clock))

        #expect(result.id == "test.scripted")
        #expect(result.outcome == .completed)
        #expect(result.metric("load")?.value == 120)
        #expect(result.metric("load")?.unit == .milliseconds)
        #expect(result.metric("rtfx")?.formatted == "12.5×")
        let chunk = try #require(result.latencies["chunk"])
        #expect(chunk.count == 4)
        #expect(chunk.minimum == 10)
        #expect(chunk.maximum == 40)
        #expect(result.notes == ["scripted"])
        #expect(result.wallTimeSeconds == 0.22)
        #expect(progress.withLock { $0.map(\.fraction) } == [0.25, 0.5, 0.75, 1])
        #expect(progress.withLock { $0.allSatisfy { $0.benchmarkID == "test.scripted" } })
    }

    @Test func skipBecomesASkippedOutcome() async {
        struct Skipping: BenchmarkCase {
            var id: String { "test.skip" }
            var title: String { "Skip" }
            var category: LogCategory { .memory }
            func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
                throw BenchmarkSkip("model not installed")
            }
        }
        let result = await BenchmarkRunner(context: Self.context(ManualClock())).run(Skipping())
        #expect(result.outcome == .skipped(reason: "model not installed"))
    }

    @Test func failureKeepsWhatWasRecorded() async {
        let clock = ManualClock()
        let result = await BenchmarkRunner(context: Self.context(clock)).run(
            ScriptedCase(clock: clock, failure: Boom()))
        #expect(result.outcome == .failed(message: "boom"))
        #expect(result.metric("load")?.value == 120)
        #expect(result.metric("rtfx") == nil)
    }

    @Test func cancelledTaskFailsAsCancelled() async {
        let clock = ManualClock()
        let runner = BenchmarkRunner(context: Self.context(clock))
        let task = Task { await runner.run(ScriptedCase(clock: clock)) }
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .failed(message: "Cancelled"))
    }

    @Test func recordsThermalStateAtStartAndEnd() async {
        let clock = ManualClock()
        let runner = BenchmarkRunner(context: Self.context(clock, thermal: [.fair, .serious]))
        let result = await runner.run(ScriptedCase(clock: clock))
        #expect(result.thermalStateAtStart == .fair)
        #expect(result.thermalStateAtEnd == .serious)
        #expect(result.wasThrottled)
    }

    @Test func runsCasesInOrderIntoAReport() async {
        let clock = ManualClock()
        let device = BenchmarkDevice.fixture(identifier: "iPhone17,1")
        let report = await BenchmarkRunner(context: Self.context(clock)).run(
            [ScriptedCase(id: "a", clock: clock), ScriptedCase(id: "b", clock: clock, failure: Boom())],
            device: device)
        #expect(report.results.map(\.id) == ["a", "b"])
        #expect(report.results.map(\.outcome.isCompleted) == [true, false])
        #expect(report.device == device)
    }

    @Test func recorderReplacesARepeatedKeyAndIgnoresNonFiniteValues() {
        let recorder = BenchmarkRecorder(benchmarkID: "x")
        recorder.record("a", 1, unit: .count)
        recorder.record("b", 2, unit: .count)
        recorder.record("a", 3, unit: .count)
        recorder.record("c", .nan, unit: .count)
        recorder.record("d", bytes: nil)
        recorder.record("e", bytes: 3 * 1_048_576)
        #expect(recorder.metrics.map(\.key) == ["a", "b", "e"])
        #expect(recorder.metrics.first?.value == 3)
        #expect(recorder.metrics.last?.value == 3)
        #expect(recorder.metrics.last?.unit == .megabytes)
    }

    @Test func describesObjectiveCErrorsWithDomainAndCode() {
        let coreML = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [NSLocalizedDescriptionKey: "E5 failed"])
        #expect(BenchmarkRunner.describe(coreML) == "E5 failed [com.apple.CoreML 0]")
        #expect(BenchmarkRunner.describe(Boom()) == "boom")
    }

    @Test(arguments: [
        (BenchmarkMetric(key: "k", value: 1234.4, unit: .milliseconds), "1234 ms"),
        (BenchmarkMetric(key: "k", value: 42.26, unit: .milliseconds), "42.3 ms"),
        (BenchmarkMetric(key: "k", value: 3.14159, unit: .megabytes), "3.14 MB"),
        (BenchmarkMetric(key: "k", value: 18.04, unit: .realTimeFactor), "18.0×"),
        (BenchmarkMetric(key: "k", value: 256, unit: .count), "256"),
        (BenchmarkMetric(key: "k", value: 37.5, unit: .percent), "37.5%"),
    ])
    func formatsMetrics(metric: BenchmarkMetric, expected: String) {
        #expect(metric.formatted == expected)
    }
}

/// Returns a fixed reading.
struct ScriptedMemoryProbe: MemoryProbe {
    var reading = MemorySnapshot(physicalFootprint: 100, peakPhysicalFootprint: nil, neural: nil, available: nil)
    func snapshot() -> MemorySnapshot? { reading }
}

extension BenchmarkDevice {
    static func fixture(
        identifier: String,
        simulator: Bool = false,
        operatingSystem: String = "iOS 27.2 (Build 24C5054e)"
    ) -> BenchmarkDevice {
        let known = BenchmarkDevice.lookup(identifier)
        return BenchmarkDevice(
            modelIdentifier: identifier, marketingName: known?.name, chip: known?.chip,
            operatingSystem: operatingSystem, physicalMemoryBytes: 8 << 30, activeProcessorCount: 6,
            isSimulator: simulator)
    }
}
