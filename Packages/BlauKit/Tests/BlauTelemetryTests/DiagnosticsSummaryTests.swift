import BlauTelemetry
import Foundation
import Testing

@Suite("Duration histograms")
struct DurationHistogramTests {
    /// 2 samples in 0.25–0.5 s, 1 in 0.5–1 s, 1 in 2–4 s.
    let histogram = DurationHistogram(buckets: [
        .init(start: 2, end: 4, count: 1),
        .init(start: 0.25, end: 0.5, count: 2),
        .init(start: 0.5, end: 1, count: 1),
        .init(start: 1, end: 2, count: 0),
    ])

    @Test func sortsBucketsByStart() {
        #expect(histogram.buckets.map(\.start) == [0.25, 0.5, 1, 2])
    }

    @Test func countsSamples() {
        #expect(histogram.sampleCount == 4)
    }

    @Test func estimatesTotalAndMeanFromMidpoints() throws {
        // 2 × 0.375 + 0.75 + 3 = 4.5
        #expect(abs(histogram.estimatedTotal - 4.5) < 1e-9)
        let mean = try #require(histogram.estimatedMean)
        #expect(abs(mean - 1.125) < 1e-9)
    }

    @Test func quantilesReportTheBucketUpperBound() {
        #expect(histogram.estimatedQuantile(0) == 0.5)
        #expect(histogram.estimatedQuantile(0.5) == 0.5)
        #expect(histogram.estimatedQuantile(0.75) == 1)
        #expect(histogram.estimatedQuantile(0.95) == 4)
        #expect(histogram.estimatedQuantile(1) == 4)
        #expect(histogram.estimatedQuantile(7) == 4, "fractions are clamped")
    }

    @Test func upperBoundIgnoresEmptyBuckets() {
        let trailingEmpty = DurationHistogram(buckets: [
            .init(start: 0, end: 1, count: 3), .init(start: 1, end: 2, count: 0),
        ])
        #expect(trailingEmpty.upperBound == 1)
    }

    @Test func emptyHistogramHasNoEstimates() {
        let empty = DurationHistogram(buckets: [.init(start: 0, end: 1, count: 0)])
        #expect(empty.sampleCount == 0)
        #expect(empty.estimatedMean == nil)
        #expect(empty.estimatedQuantile(0.5) == nil)
        #expect(empty.upperBound == nil)
    }

    @Test func mergeAddsMatchingBucketsAndKeepsTheRest() {
        let other = DurationHistogram(buckets: [
            .init(start: 0.25, end: 0.5, count: 3),
            .init(start: 8, end: 16, count: 1),
        ])
        let merged = histogram.merged(with: other)
        #expect(merged.sampleCount == histogram.sampleCount + other.sampleCount)
        #expect(merged.buckets.first { $0.start == 0.25 }?.count == 5)
        #expect(merged.buckets.last?.start == 8)
        #expect(merged.buckets.map(\.start) == merged.buckets.map(\.start).sorted())
    }
}

@Suite("Diagnostics summaries")
struct DiagnosticsSummaryTests {
    @Test func exitCountsSplitUnexpectedAndMemoryExits() {
        let exits = AppExitCounts(
            normal: 10, memoryResourceLimit: 1, badAccess: 2, abnormal: 1, illegalInstruction: 1, watchdog: 1,
            cpuResourceLimit: 1, memoryPressure: 3, suspendedWithLockedFile: 1, backgroundTaskAssertionTimeout: 1)
        #expect(exits.unexpected == 12)
        #expect(exits.memoryRelated == 4)
    }

    @Test(arguments: [
        (CrashEvent(signal: 11), "SIGSEGV"),
        (CrashEvent(signal: 6), "SIGABRT"),
        (CrashEvent(signal: 99), "signal 99"),
        (CrashEvent(exceptionType: 1), "exception type 1"),
        (CrashEvent(signal: 6, objectiveCExceptionName: "NSInvalidArgumentException"), "NSInvalidArgumentException"),
        (CrashEvent(), "crash"),
    ])
    func crashLabels(crash: CrashEvent, label: String) {
        #expect(crash.label == label)
    }

    @Test func payloadSummaryExposesCommonFields() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let environment = PayloadEnvironment(appVersion: "1.0", isTestFlightApp: true)
        let metrics = PayloadSummary.metrics(
            MetricPayloadSummary(periodStart: start, periodEnd: end, environment: environment))
        let diagnostics = PayloadSummary.diagnostics(DiagnosticPayloadSummary(periodStart: start, periodEnd: end))

        #expect(metrics.kind == .metrics)
        #expect(diagnostics.kind == .diagnostics)
        #expect(metrics.periodStart == start && metrics.periodEnd == end)
        #expect(metrics.environment == environment)
        #expect(diagnostics.environment == PayloadEnvironment())
    }

    @Test func recordsRoundTripThroughJSON() throws {
        let sample = DiagnosticsSamples.metricPayload(periodEnd: Date(timeIntervalSince1970: 1_800_000_000))
        let record = DiagnosticsRecord(
            id: "abc", receivedAt: Date(timeIntervalSince1970: 1_800_000_100), summary: sample.summary)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsRecord.self, from: encoder.encode(record))
        #expect(decoded == record)
    }

    @Test func samplesAreValidJSONMarkedAsSamples() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        for sample in [
            DiagnosticsSamples.metricPayload(periodEnd: end), DiagnosticsSamples.diagnosticPayload(periodEnd: end),
        ] {
            let object = try #require(try JSONSerialization.jsonObject(with: sample.json) as? [String: Any])
            #expect(object["blauSample"] as? Bool == true)
            #expect(object["timeStampBegin"] is String)
        }
    }
}
