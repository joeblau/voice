import Foundation

/// What the Developer diagnostics screen shows: hangs, memory, stability,
/// launch time and Blau's own signposts, rolled up across every stored
/// payload.
///
/// Built from `DiagnosticsRecord`s, so it is pure and tested on the Mac.
public struct DiagnosticsOverview: Codable, Sendable, Hashable {
    // MARK: Payloads

    public var metricPayloadCount = 0
    public var diagnosticPayloadCount = 0
    /// Payloads whose metadata says they came from a TestFlight install.
    public var testFlightPayloadCount = 0
    /// Earliest period start across all payloads.
    public var firstPeriodStart: Date?
    /// Latest period end across all payloads.
    public var lastPeriodEnd: Date?
    /// When the newest payload arrived on this device.
    public var lastReceivedAt: Date?
    /// App version of the newest payload.
    public var latestAppVersion: String?

    // MARK: Hangs

    /// Hang reports with call stacks (`MXHangDiagnostic`).
    public var hangReportCount = 0
    public var longestHangSeconds: Double?
    /// Hangs counted by the daily metrics (`histogrammedApplicationHangTime`),
    /// merged across payloads.
    public var hangTime: DurationHistogram?

    // MARK: Memory

    /// Highest peak memory across all metric payloads, in bytes.
    public var peakMemoryBytes: Double?
    /// Peak memory in the newest metric payload, in bytes.
    public var latestPeakMemoryBytes: Double?
    /// Average memory while suspended in the newest metric payload, in bytes.
    public var latestAverageSuspendedMemoryBytes: Double?
    /// Exits caused by the memory limit or memory pressure.
    public var memoryExitCount = 0

    // MARK: Stability

    public var crashCount = 0
    /// The most common crash labels, most frequent first.
    public var topCrashes: [LabelCount] = []
    public var cpuExceptionCount = 0
    public var diskWriteExceptionCount = 0
    /// Unexpected exits (foreground and background) from the daily metrics.
    public var unexpectedExitCount = 0

    // MARK: Launch

    public var timeToFirstDraw: DurationHistogram?
    public var slowLaunchReportCount = 0

    // MARK: Signposts

    /// Blau's MetricKit signposts, merged by category and name, sorted by name.
    public var signposts: [SignpostMetricSummary] = []

    /// A label and how often it occurred.
    public struct LabelCount: Codable, Sendable, Hashable {
        public var label: String
        public var count: Int

        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public init() {}

    /// Rolls `records` up. Order doesn't matter.
    public init(records: [DiagnosticsRecord]) {
        let byArrival = records.sorted { ($0.receivedAt, $0.summary.periodEnd) < ($1.receivedAt, $1.summary.periodEnd) }

        var crashLabels: [String: Int] = [:]
        var signpostsByKey: [String: SignpostMetricSummary] = [:]

        for record in byArrival {
            let summary = record.summary
            firstPeriodStart = min(firstPeriodStart ?? summary.periodStart, summary.periodStart)
            lastPeriodEnd = max(lastPeriodEnd ?? summary.periodEnd, summary.periodEnd)
            lastReceivedAt = max(lastReceivedAt ?? record.receivedAt, record.receivedAt)
            if summary.environment.isTestFlightApp == true {
                testFlightPayloadCount += 1
            }
            if let version = summary.environment.appVersion {
                latestAppVersion = version
            }

            switch summary {
            case .metrics(let metrics):
                metricPayloadCount += 1
                if let version = metrics.latestAppVersion {
                    latestAppVersion = version
                }
                add(metrics, signposts: &signpostsByKey)
            case .diagnostics(let diagnostics):
                diagnosticPayloadCount += 1
                add(diagnostics, crashLabels: &crashLabels)
            }
        }

        topCrashes =
            crashLabels
            .map { LabelCount(label: $0.key, count: $0.value) }
            .sorted { ($1.count, $0.label) < ($0.count, $1.label) }
        signposts = signpostsByKey.values.sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    /// Whether any payload has been stored yet.
    public var isEmpty: Bool { metricPayloadCount == 0 && diagnosticPayloadCount == 0 }

    /// Hangs from both sources: the daily metric counts plus hang reports.
    /// The two overlap (a reported hang is also counted in the metrics), so
    /// the screen shows them separately; this is the larger of the two.
    public var hangCount: Int { max(hangTime?.sampleCount ?? 0, hangReportCount) }

    private mutating func add(_ metrics: MetricPayloadSummary, signposts: inout [String: SignpostMetricSummary]) {
        if let peak = metrics.peakMemoryBytes {
            peakMemoryBytes = max(peakMemoryBytes ?? peak, peak)
            latestPeakMemoryBytes = peak
        }
        if let suspended = metrics.averageSuspendedMemoryBytes {
            latestAverageSuspendedMemoryBytes = suspended
        }
        hangTime = Self.merge(hangTime, metrics.hangTime)
        timeToFirstDraw = Self.merge(timeToFirstDraw, metrics.timeToFirstDraw)

        for exits in [metrics.foregroundExits, metrics.backgroundExits].compactMap(\.self) {
            unexpectedExitCount += exits.unexpected
            memoryExitCount += exits.memoryRelated
        }

        for signpost in metrics.signposts {
            let key = "\(signpost.category)\u{1F}\(signpost.name)"
            guard var existing = signposts[key] else {
                signposts[key] = signpost
                continue
            }
            existing.totalCount += signpost.totalCount
            existing.duration = Self.merge(existing.duration, signpost.duration)
            existing.cumulativeCPUSeconds = Self.sum(existing.cumulativeCPUSeconds, signpost.cumulativeCPUSeconds)
            existing.cumulativeLogicalWriteBytes = Self.sum(
                existing.cumulativeLogicalWriteBytes, signpost.cumulativeLogicalWriteBytes)
            existing.averageMemoryBytes = signpost.averageMemoryBytes ?? existing.averageMemoryBytes
            signposts[key] = existing
        }
    }

    private mutating func add(_ diagnostics: DiagnosticPayloadSummary, crashLabels: inout [String: Int]) {
        hangReportCount += diagnostics.hangs.count
        if let longest = diagnostics.hangs.map(\.durationSeconds).max() {
            longestHangSeconds = max(longestHangSeconds ?? longest, longest)
        }
        crashCount += diagnostics.crashes.count
        for crash in diagnostics.crashes {
            crashLabels[crash.label, default: 0] += 1
        }
        cpuExceptionCount += diagnostics.cpuExceptions.count
        diskWriteExceptionCount += diagnostics.diskWriteExceptions.count
        slowLaunchReportCount += diagnostics.slowLaunchSeconds.count
    }

    private static func merge(_ lhs: DurationHistogram?, _ rhs: DurationHistogram?) -> DurationHistogram? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (let lhs?, let rhs?): lhs.merged(with: rhs)
        }
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        default: (lhs ?? 0) + (rhs ?? 0)
        }
    }
}
