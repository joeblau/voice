import BlauCore
import BlauTopics
import Foundation
import Testing
import XCTest

/// The cost of one segmenter update (`TopicSegmenter.append`, the work inside
/// the `topics.segment` interval), excluding the embedding.
///
/// The budget is < 5 ms per update on device (#52). The workload is a
/// two-hour conversation: 400 exchanges of 1,024-d vectors (larger than the
/// 512-d contextual and 256-d EmbeddingGemma vectors production uses), with
/// a topic change every 12 exchanges plus one 120-exchange topic, the worst
/// case for the depth search.
enum SegmenterWorkload {
    static let dimension = 1024
    static let count = 400

    static func make() -> [(unit: TopicUnit, embedding: [Float])] {
        var generator = SplitMix64(seed: 2026)
        let units = makeUnits(count, every: .seconds(18))
        return units.enumerated().map { index, unit in
            let topic = index < 120 ? 0 : 1 + (index - 120) / 12
            var vector = (0..<dimension).map { _ in Float.random(in: -0.2...0.2, using: &generator) }
            vector[(topic * 37) % dimension] += 1
            return (unit, vector)
        }
    }
}

@Suite("TopicSegmenter update cost")
struct TopicSegmenterBudgetTests {
    /// Measures every update and checks the 99th percentile against the
    /// budget.
    ///
    /// The engine is deterministic, so the workload is replayed several times
    /// and each update keeps its fastest time: that filters out preemption by
    /// the other test suites running in parallel, which would otherwise make
    /// this flaky. It runs in the unoptimized test build on the Mac host, so
    /// passing here is a smoke check, not the on-device measurement.
    @Test func everyUpdateFitsTheBudget() throws {
        let workload = SegmenterWorkload.make()
        let clock = ContinuousClock()
        var fastest = [Duration](repeating: .seconds(1_000), count: workload.count)
        var boundaries = 0
        for _ in 0..<5 {
            var segmenter = TopicSegmenter()
            for (index, (unit, embedding)) in workload.enumerated() {
                let start = clock.now
                _ = try segmenter.append(unit, embedding: embedding)
                fastest[index] = min(fastest[index], clock.now - start)
            }
            boundaries = segmenter.boundaries.count
        }
        let sorted = fastest.sorted()
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[sorted.count * 99 / 100]
        let worst = sorted[sorted.count - 1]
        print("TopicSegmenter update: p50 \(p50), p99 \(p99), max \(worst) (\(workload.count) updates)")
        #expect(p99 < .milliseconds(5), "p50 \(p50), p99 \(p99), max \(worst)")
        #expect(boundaries > 0)
    }
}

/// XCTest performance metrics for the same workload, for the perf suite
/// (#73) and for running on a device:
///
///     xcodebuild test -scheme BlauKit-Package \
///       -destination 'platform=iOS,id=<device udid>' \
///       -only-testing:BlauTopicsTests/TopicSegmenterPerformanceTests
final class TopicSegmenterPerformanceTests: XCTestCase {
    func testTwoHourConversationUpdates() throws {
        let workload = SegmenterWorkload.make()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            var segmenter = TopicSegmenter()
            for (unit, embedding) in workload {
                _ = try? segmenter.append(unit, embedding: embedding)
            }
        }
    }
}
