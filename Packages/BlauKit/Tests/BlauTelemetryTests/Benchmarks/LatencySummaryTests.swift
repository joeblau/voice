import BlauTelemetry
import Foundation
import Testing

@Suite("Latency summary")
struct LatencySummaryTests {
    @Test func summarizesOneToTen() throws {
        let summary = try #require(LatencySummary(milliseconds: (1...10).map(Double.init).shuffled()))
        #expect(summary.count == 10)
        #expect(summary.minimum == 1)
        #expect(summary.maximum == 10)
        #expect(summary.mean == 5.5)
        // Linear interpolation between closest ranks (NumPy's default).
        #expect(summary.p50 == 5.5)
        #expect(abs(summary.p90 - 9.1) < 1e-9)
        #expect(abs(summary.p95 - 9.55) < 1e-9)
        #expect(abs(summary.p99 - 9.91) < 1e-9)
        #expect(abs(summary.standardDeviation - 8.25.squareRoot()) < 1e-9)
    }

    @Test func singleSampleIsEveryPercentile() throws {
        let summary = try #require(LatencySummary(milliseconds: [42]))
        #expect([summary.minimum, summary.p50, summary.p95, summary.p99, summary.maximum] == [42, 42, 42, 42, 42])
        #expect(summary.standardDeviation == 0)
    }

    @Test func rejectsEmptyAndNonFiniteSamples() {
        #expect(LatencySummary(milliseconds: []) == nil)
        #expect(LatencySummary(milliseconds: [1, .nan]) == nil)
        #expect(LatencySummary(milliseconds: [1, .infinity]) == nil)
        #expect(LatencySummary([Duration]()) == nil)
    }

    @Test func convertsDurationsToMilliseconds() throws {
        let summary = try #require(LatencySummary([.milliseconds(10), .microseconds(20_500), .seconds(1)]))
        #expect(summary.minimum == 10)
        #expect(summary.p50 == 20.5)
        #expect(summary.maximum == 1_000)
        #expect(Duration.milliseconds(250).milliseconds == 250)
    }

    @Test func percentileEndpoints() {
        let sorted = [1.0, 2, 3, 4]
        #expect(LatencySummary.percentile(0, ofSorted: sorted) == 1)
        #expect(LatencySummary.percentile(1, ofSorted: sorted) == 4)
        #expect(LatencySummary.percentile(0.5, ofSorted: sorted) == 2.5)
    }

    @Test func roundTripsThroughJSON() throws {
        let summary = try #require(LatencySummary(milliseconds: [3, 1, 2]))
        let decoded = try JSONDecoder().decode(LatencySummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded == summary)
    }
}
