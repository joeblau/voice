import BlauCore
import Foundation
import Synchronization
import os

/// One measurement in the on-device benchmark suite (#22), such as
/// "Parakeet EOU at 320 ms" or "Foundation Models topic label".
///
/// A case does its own setup (downloading or locating its model), measures
/// with `context`, and reports through `recorder`. Throw `BenchmarkSkip`
/// when it can't run on this device; any other error marks the result
/// failed while keeping what was recorded so far.
///
/// Cases live in the module that owns the model (`BlauTranscription`,
/// `BlauVoiceID`, ...) and wrap the real implementation behind a protocol, so
/// the measuring logic is unit tested on the Mac with fakes. The app's
/// debug benchmark screen and the `BlauBenchmarks` XCTest target compose
/// them. See docs/benchmarks.md.
public protocol BenchmarkCase: Sendable {
    /// Stable identifier, for example `asr.eou.320ms`. Results from
    /// different devices are matched on it.
    var id: String { get }
    /// Human-readable name.
    var title: String { get }
    /// Where the runner logs progress for this case.
    var category: LogCategory { get }

    func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws
}

/// Thrown by a case that cannot run here, for example because its model is
/// not installed or Apple Intelligence is off. The result is marked
/// skipped with `reason`.
public struct BenchmarkSkip: Error, Hashable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Progress of a running case, for the benchmark screen.
public struct BenchmarkProgress: Hashable, Sendable {
    public let benchmarkID: String
    /// `0...1`, or `nil` when the step has no measurable progress
    /// (a model download of unknown size, a compile).
    public let fraction: Double?
    public let message: String

    public init(benchmarkID: String, fraction: Double?, message: String) {
        self.benchmarkID = benchmarkID
        self.fraction = fraction
        self.message = message
    }
}

/// What a case measures with: the clock, the memory probe and the thermal
/// state. Tests inject a `ManualClock` and scripted probes.
public struct BenchmarkContext: Sendable {
    public let clock: any BlauClock
    public let memory: any MemoryProbe
    public let thermalState: @Sendable () -> ThermalState

    public init(
        clock: any BlauClock = SystemClock(),
        memory: any MemoryProbe = ProcessMemoryProbe(),
        thermalState: @escaping @Sendable () -> ThermalState = { ThermalState.current }
    ) {
        self.clock = clock
        self.memory = memory
        self.thermalState = thermalState
    }

    /// Runs `body` and returns its value with the monotonic time it took.
    public func measure<T, E: Error>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(E) -> T
    ) async throws(E) -> (value: T, duration: Duration) {
        let start = clock.uptime
        let value = try await body()
        return (value, clock.uptime - start)
    }

    /// Runs synchronous `body` and returns its value with the time it took.
    public func measure<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> (value: T, duration: Duration) {
        let start = clock.uptime
        let value = try body()
        return (value, clock.uptime - start)
    }

    /// Starts tracking memory from now.
    public func memoryWatermark() -> MemoryWatermark {
        MemoryWatermark(probe: memory)
    }
}

/// Collects what a case measures. Thread safe, so a case may record from
/// any task.
public final class BenchmarkRecorder: Sendable {
    private struct State {
        var metrics: [BenchmarkMetric] = []
        var latencies: [String: LatencySummary] = [:]
        var notes: [String] = []
    }

    public let benchmarkID: String
    private let state = Mutex(State())
    private let onProgress: @Sendable (BenchmarkProgress) -> Void

    public init(benchmarkID: String, onProgress: @escaping @Sendable (BenchmarkProgress) -> Void = { _ in }) {
        self.benchmarkID = benchmarkID
        self.onProgress = onProgress
    }

    /// Records a scalar. Recording a key again replaces the earlier value
    /// in place.
    public func record(_ key: String, _ value: Double, unit: BenchmarkMetric.Unit) {
        guard value.isFinite else { return }
        let metric = BenchmarkMetric(key: key, value: value, unit: unit)
        state.withLock { state in
            if let index = state.metrics.firstIndex(where: { $0.key == key }) {
                state.metrics[index] = metric
            } else {
                state.metrics.append(metric)
            }
        }
    }

    /// Records a duration in milliseconds.
    public func record(_ key: String, _ duration: Duration) {
        record(key, duration.milliseconds, unit: .milliseconds)
    }

    /// Records a byte count in megabytes. Does nothing for `nil`.
    public func record(_ key: String, bytes: UInt64?) {
        guard let bytes else { return }
        record(key, bytes.megabytes, unit: .megabytes)
    }

    /// Records the distribution of `samples` under `key`. Does nothing for an
    /// empty sample.
    public func recordLatencies(_ key: String, _ samples: [Duration]) {
        guard let summary = LatencySummary(samples) else { return }
        state.withLock { $0.latencies[key] = summary }
    }

    /// Records the standard memory metrics from `watermark`:
    /// `memory.footprint` (latest), `memory.footprintGrowth` (highest above
    /// the baseline) and `memory.neuralGrowth`.
    public func recordMemory(_ watermark: MemoryWatermark) {
        record("memory.footprint", bytes: watermark.latest?.physicalFootprint)
        record("memory.footprintGrowth", bytes: watermark.footprintGrowth)
        record("memory.neuralGrowth", bytes: watermark.neuralGrowth)
    }

    /// Adds an observation to the result.
    public func note(_ text: String) {
        state.withLock { $0.notes.append(text) }
    }

    /// Reports progress to the runner's observer.
    public func progress(_ fraction: Double?, _ message: String) {
        onProgress(
            BenchmarkProgress(
                benchmarkID: benchmarkID, fraction: fraction.map { min(max($0, 0), 1) }, message: message))
    }

    public var metrics: [BenchmarkMetric] { state.withLock { $0.metrics } }
    public var latencies: [String: LatencySummary] { state.withLock { $0.latencies } }
    public var notes: [String] { state.withLock { $0.notes } }
}

/// Runs benchmark cases one after another and turns each into a
/// `BenchmarkResult`.
///
/// Cases never run concurrently: they compete for the same Neural Engine,
/// memory and thermal headroom.
public struct BenchmarkRunner: Sendable {
    public let context: BenchmarkContext
    private let onProgress: @Sendable (BenchmarkProgress) -> Void

    public init(
        context: BenchmarkContext = BenchmarkContext(),
        onProgress: @escaping @Sendable (BenchmarkProgress) -> Void = { _ in }
    ) {
        self.context = context
        self.onProgress = onProgress
    }

    /// Runs one case. Never throws: skips, failures and cancellation are
    /// reported in the result's `outcome`.
    public func run(_ benchmark: any BenchmarkCase) async -> BenchmarkResult {
        let log = Log.logger(for: benchmark.category)
        let recorder = BenchmarkRecorder(benchmarkID: benchmark.id, onProgress: onProgress)
        let startedAt = context.clock.now
        let start = context.clock.uptime
        let thermalAtStart = context.thermalState()
        log.notice("Benchmark \(benchmark.id, privacy: .public) started")

        let outcome: BenchmarkResult.Outcome
        do {
            try Task.checkCancellation()
            try await benchmark.run(recorder: recorder, context: context)
            outcome = .completed
        } catch let skip as BenchmarkSkip {
            outcome = .skipped(reason: skip.reason)
        } catch is CancellationError {
            outcome = .failed(message: "Cancelled")
        } catch {
            outcome = .failed(message: Self.describe(error))
        }

        let wallTime = context.clock.uptime - start
        switch outcome {
        case .completed:
            log.notice(
                "Benchmark \(benchmark.id, privacy: .public) completed in \(wallTime.timeInterval, format: .fixed(precision: 1), privacy: .public) s"
            )
        case .skipped(let reason):
            log.notice("Benchmark \(benchmark.id, privacy: .public) skipped: \(reason, privacy: .public)")
        case .failed(let message):
            log.error("Benchmark \(benchmark.id, privacy: .public) failed: \(message, privacy: .public)")
        }

        return BenchmarkResult(
            id: benchmark.id,
            title: benchmark.title,
            outcome: outcome,
            metrics: recorder.metrics,
            latencies: recorder.latencies,
            notes: recorder.notes,
            startedAt: startedAt,
            wallTimeSeconds: wallTime.timeInterval,
            thermalStateAtStart: thermalAtStart,
            thermalStateAtEnd: context.thermalState()
        )
    }

    /// Runs `cases` in order and collects a report for `device`. Stops
    /// early (marking the rest as skipped) if the task is cancelled.
    public func run(_ cases: [any BenchmarkCase], device: BenchmarkDevice = .current) async -> BenchmarkReport {
        var results: [BenchmarkResult] = []
        let startedAt = context.clock.now
        for benchmark in cases {
            if Task.isCancelled {
                results.append(skippedResult(for: benchmark, reason: "Run cancelled"))
                continue
            }
            results.append(await run(benchmark))
        }
        return BenchmarkReport(device: device, startedAt: startedAt, results: results)
    }

    private func skippedResult(for benchmark: any BenchmarkCase, reason: String) -> BenchmarkResult {
        let thermal = context.thermalState()
        return BenchmarkResult(
            id: benchmark.id, title: benchmark.title, outcome: .skipped(reason: reason), metrics: [],
            latencies: [:], notes: [], startedAt: context.clock.now, wallTimeSeconds: 0,
            thermalStateAtStart: thermal, thermalStateAtEnd: thermal)
    }

    /// A one-line description of `error` that includes the domain and code
    /// of `NSError`s (Core ML reports most failures that way).
    public static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        // A Swift error bridges to an NSError whose domain is its own type
        // name; only Objective-C errors (Core ML, Foundation) carry a useful
        // domain and code.
        let isSwiftError = nsError.domain == String(reflecting: type(of: error))
        if let description = (error as? LocalizedError)?.errorDescription, isSwiftError {
            return description
        }
        if isSwiftError {
            return String(describing: error)
        }
        let message = nsError.localizedDescription
        return message.contains(nsError.domain) ? message : "\(message) [\(nsError.domain) \(nsError.code)]"
    }
}
