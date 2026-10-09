import BlauTelemetry
import Foundation
import Testing

@Suite("Diagnostics overview")
struct DiagnosticsOverviewTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static func metrics(
        day index: Int,
        receivedAt: Date? = nil,
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
            receivedAt: receivedAt ?? end.addingTimeInterval(60),
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
        launches: [Double] = [],
        version: String? = nil
    ) -> DiagnosticsRecord {
        let end = origin.addingTimeInterval(Double(index) * day)
        return DiagnosticsRecord(
            id: "d\(index)",
            receivedAt: end.addingTimeInterval(30),
            summary: .diagnostics(
                DiagnosticPayloadSummary(
                    periodStart: end.addingTimeInterval(-3_600),
                    periodEnd: end,
                    environment: PayloadEnvironment(appVersion: version),
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

    @Test func latestVersionComesFromTheNewestPeriod() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 3, version: "0.3.0"),
            Self.metrics(day: 1, version: "0.1.0"),
            Self.metrics(day: 2, version: "0.2.0"),
        ])
        #expect(overview.latestAppVersion == "0.3.0")
    }

    @Test func latestValuesFollowThePeriodNotTheDelivery() {
        // At the first launch after an update, MetricKit hands over past
        // payloads in one batch, in no guaranteed order: here the newest
        // period is saved first.
        let batch = Self.origin.addingTimeInterval(10 * Self.day)
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 3, receivedAt: batch, peak: 300e6, suspended: 30e6, version: "0.3.0"),
            Self.metrics(
                day: 2, receivedAt: batch.addingTimeInterval(0.01), peak: 200e6, suspended: 20e6, version: "0.2.0"),
            Self.metrics(
                day: 1, receivedAt: batch.addingTimeInterval(0.02), peak: 100e6, suspended: 10e6, version: "0.1.0"),
        ])
        #expect(overview.latestPeakMemoryBytes == 300e6)
        #expect(overview.latestAverageSuspendedMemoryBytes == 30e6)
        #expect(overview.latestAppVersion == "0.3.0")
        #expect(overview.lastReceivedAt == batch.addingTimeInterval(0.02))
    }

    @Test func latestVersionComesFromTheNewestPeriodAcrossKinds() {
        // A diagnostic payload for an older period, delivered last, doesn't
        // override the version of a newer metric payload.
        let overview = DiagnosticsOverview(records: [
            Self.metrics(day: 2, version: "0.2.0"),
            Self.diagnostics(day: 5, version: "0.5.0"),
        ])
        #expect(overview.latestAppVersion == "0.5.0")
        let older = DiagnosticsOverview(records: [
            Self.metrics(day: 5, receivedAt: Self.origin, version: "0.5.0"),
            Self.diagnostics(day: 2, version: "0.2.0"),
        ])
        #expect(older.latestAppVersion == "0.5.0")
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

    @Test func slowLaunchReportsAloneCountAsLaunchData() {
        // A device that has only delivered an MXAppLaunchDiagnostic: no
        // metric payload, so no time-to-first-draw histogram.
        let overview = DiagnosticsOverview(records: [Self.diagnostics(day: 1, launches: [4.2])])
        #expect(overview.timeToFirstDraw == nil)
        #expect(overview.hasLaunchData)
    }

    @Test func launchDataNeedsMeasuredLaunchesOrReports() {
        #expect(!DiagnosticsOverview(records: [Self.metrics(day: 1)]).hasLaunchData)
        var measured = DiagnosticsOverview()
        measured.timeToFirstDraw = DurationHistogram(buckets: [.init(start: 0.5, end: 0.6, count: 3)])
        #expect(measured.hasLaunchData)
        measured.timeToFirstDraw = DurationHistogram(buckets: [])
        #expect(!measured.hasLaunchData)
    }

    @Test func signpostsWithTheSameNameInTwoCategoriesHaveDistinctIDs() {
        let overview = DiagnosticsOverview(records: [
            Self.metrics(
                day: 1,
                signposts: [
                    SignpostMetricSummary(category: "asr", name: "chunk", totalCount: 3),
                    SignpostMetricSummary(category: "vad", name: "chunk", totalCount: 4),
                ])
        ])
        #expect(overview.signposts.count == 2)
        #expect(Set(overview.signposts.map(\.id)).count == 2)
        #expect(overview.signposts.map(\.totalCount) == [3, 4])
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
