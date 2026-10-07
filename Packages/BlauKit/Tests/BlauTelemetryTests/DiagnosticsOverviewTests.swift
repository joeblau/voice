import BlauTelemetry
import Foundation
import Testing

@Suite("Diagnostics overview")
struct DiagnosticsOverviewTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static func metrics(
        day index: Int,
        peak: Double? = nil,
        suspended: Double? = nil,
        hangs: DurationHistogram? = nil,
        version: String = "0.1.0",
        testFlight: Bool? = nil,
        foreground: AppExitCounts? = nil,
        background: AppExitCounts? = nil,
        signposts: [SignpostMetricSummary] = []
    ) -> DiagnosticsRecord {
        let end = origin.addingTimeInterval(Double(index) * day)
        return DiagnosticsRecord(
            id: "m\(index)",
            receivedAt: end.addingTimeInterval(60),
            summary: .metrics(
                MetricPayloadSummary(
                    periodStart: end.addingTimeInterval(-day),
                    periodEnd: end,
                    environment: PayloadEnvironment(appVersion: version, isTestFlightApp: testFlight),
                    latestAppVersion: version,
                    peakMemoryBytes: peak,
                    averageSuspendedMemoryBytes: suspended,
                    hangTime: hangs,
                    foregroundExits: foreground,
                    backgroundExits: background,
                    signposts: signposts
                ))
        )
    }

    static func diagnostics(
        day index: Int,
        hangs: [Double] = [],
        crashes: [CrashEvent] = [],
        cpu: Int = 0,
        disk: Int = 0,
        launches: [Double] = []
    ) -> DiagnosticsRecord {
        let end = origin.addingTimeInterval(Double(index) * day)
        return DiagnosticsRecord(
            id: "d\(index)",
            receivedAt: end.addingTimeInterval(30),
            summary: .diagnostics(
                DiagnosticPayloadSummary(
                    periodStart: end.addingTimeInterval(-3_600),
                    periodEnd: end,
                    hangs: hangs.map { HangEvent(durationSeconds: $0) },
                    crashes: crashes,
                    cpuExceptions: Array(
                        repeating: CPUExceptionEvent(totalCPUSeconds: 90, totalSampledSeconds: 180), count: cpu),
                    diskWriteExceptions: Array(repeating: DiskWriteExceptionEvent(totalWriteBytes: 1e9), count: disk),
                    slowLaunchSeconds: launches
                ))
        )
    }

    @Test func emptyOverview() {
        let overview = DiagnosticsOverview(records: [])
        #expect(overview.isEmpty)
        #expect(overview.hangCount == 0)
        #expect(overview.firstPeriodStart == nil)
        #expect(overview.peakMemoryBytes == nil)
        #expect(overview == DiagnosticsOverview())
    }

    @Test func countsPayloadsAndPeriod() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 2, testFlight: true),
            Self.diagnostics(day: 1),
            Self.metrics(day: 1, testFlight: false),
        ])
        #expect(!overview.isEmpty)
        #expect(overview.metricPayloadCount == 2)
        #expect(overview.diagnosticPayloadCount == 1)
        #expect(overview.testFlightPayloadCount == 1)
        #expect(overview.firstPeriodStart == Self.origin)
        #expect(overview.lastPeriodEnd == Self.origin.addingTimeInterval(2 * Self.day))
        #expect(overview.lastReceivedAt == Self.origin.addingTimeInterval(2 * Self.day + 60))
    }

    @Test func latestVersionComesFromTheNewestDelivery() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 3, version: "0.3.0"),
            Self.metrics(day: 1, version: "0.1.0"),
            Self.metrics(day: 2, version: "0.2.0"),
        ])
        #expect(overview.latestAppVersion == "0.3.0")
    }

    @Test func summarizesMemory() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 1, peak: 400e6, suspended: 50e6),
            Self.metrics(day: 2, peak: 300e6, suspended: 40e6),
            Self.metrics(
                day: 3, foreground: AppExitCounts(normal: 3, memoryResourceLimit: 1),
                background: AppExitCounts(normal: 5, badAccess: 1, memoryPressure: 2)),
        ])
        #expect(overview.peakMemoryBytes == 400e6)
        #expect(overview.latestPeakMemoryBytes == 300e6, "day 3 has no memory metrics")
        #expect(overview.latestAverageSuspendedMemoryBytes == 40e6)
        #expect(overview.memoryExitCount == 3)
        #expect(overview.unexpectedExitCount == 4)
    }

    @Test func summarizesHangsFromBothSources() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 1, hangs: DurationHistogram(buckets: [.init(start: 0.25, end: 0.5, count: 4)])),
            Self.metrics(
                day: 2,
                hangs: DurationHistogram(buckets: [
                    .init(start: 0.25, end: 0.5, count: 1), .init(start: 1, end: 2, count: 1),
                ])),
            Self.diagnostics(day: 1, hangs: [2.5]),
            Self.diagnostics(day: 2, hangs: [1.25, 4]),
        ])
        #expect(overview.hangReportCount == 3)
        #expect(overview.longestHangSeconds == 4)
        #expect(overview.hangTime?.sampleCount == 6)
        #expect(overview.hangTime?.buckets.count == 2)
        #expect(overview.hangCount == 6)
    }

    @Test func summarizesStability() {
        let overview = DiagnosticsOverview(records: [
            Self.diagnostics(
                day: 1, crashes: [CrashEvent(signal: 11), CrashEvent(signal: 6)], cpu: 1, disk: 2, launches: [3.1]),
            Self.diagnostics(day: 2, crashes: [CrashEvent(signal: 11)], cpu: 1),
        ])
        #expect(overview.crashCount == 3)
        #expect(
            overview.topCrashes == [
                .init(label: "SIGSEGV", count: 2), .init(label: "SIGABRT", count: 1),
            ])
        #expect(overview.cpuExceptionCount == 2)
        #expect(overview.diskWriteExceptionCount == 2)
        #expect(overview.slowLaunchReportCount == 1)
    }

    @Test func mergesSignpostsByCategoryAndName() throws {
        func firstAudio(_ count: Int, cpu: Double?) -> SignpostMetricSummary {
            SignpostMetricSummary(
                category: "realtime", name: "realtime.firstAudio", totalCount: count,
                duration: DurationHistogram(buckets: [.init(start: 0.4, end: 0.6, count: count)]),
                cumulativeCPUSeconds: cpu)
        }
        let eou = SignpostMetricSummary(category: "asr", name: "asr.eou", totalCount: 7)
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 1, signposts: [firstAudio(10, cpu: 1.5), eou]),
            Self.metrics(day: 2, signposts: [firstAudio(5, cpu: nil)]),
        ])

        #expect(overview.signposts.map(\.name) == ["asr.eou", "realtime.firstAudio"])
        let merged = try #require(overview.signposts.last)
        #expect(merged.totalCount == 15)
        #expect(merged.duration?.sampleCount == 15)
        #expect(merged.cumulativeCPUSeconds == 1.5)
    }

    @Test func orderOfRecordsDoesNotMatter() {
        let records = [
            Self.metrics(day: 1, peak: 1e6, hangs: DurationHistogram(buckets: [.init(start: 0, end: 1, count: 1)])),
            Self.metrics(day: 2, peak: 2e6),
            Self.diagnostics(day: 1, hangs: [1], crashes: [CrashEvent(signal: 11)]),
        ]
        #expect(DiagnosticsOverview(records: records) == DiagnosticsOverview(records: records.reversed()))
    }
}
