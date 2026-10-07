import Foundation

// Plain, Codable summaries of MetricKit payloads.
//
// MetricKit's own types (`MXMetricPayload`, `MXDiagnosticPayload`) can't be
// created outside MetricKit and don't exist on every platform, so everything
// Blau shows or aggregates works on these value types instead. The raw
// MetricKit JSON is stored next to each summary and goes into the export
// untouched; the summaries only feed the Developer diagnostics screen.

/// Which MetricKit delivery a payload came from.
public enum DiagnosticsPayloadKind: String, Codable, Sendable, CaseIterable {
    /// `MXMetricPayload`: aggregated metrics, delivered at most once a day.
    case metrics
    /// `MXDiagnosticPayload`: hang, crash, CPU and disk-write exception
    /// reports with call stacks.
    case diagnostics
}

/// The build and device a payload describes (`MXMetaData`).
public struct PayloadEnvironment: Codable, Sendable, Hashable {
    public var appVersion: String?
    public var appBuild: String?
    public var osVersion: String?
    public var deviceType: String?
    public var platformArchitecture: String?
    /// Whether the payload came from a TestFlight install.
    public var isTestFlightApp: Bool?
    public var isLowPowerModeEnabled: Bool?

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String? = nil,
        deviceType: String? = nil,
        platformArchitecture: String? = nil,
        isTestFlightApp: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.platformArchitecture = platformArchitecture
        self.isTestFlightApp = isTestFlightApp
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

// MARK: - Histograms

/// A MetricKit duration histogram (`MXHistogram<UnitDuration>`) in seconds.
///
/// MetricKit only reports bucket counts, so totals, means and percentiles are
/// estimates: totals use each bucket's midpoint, percentiles report the upper
/// bound of the bucket the sample falls in (a conservative reading).
public struct DurationHistogram: Codable, Sendable, Hashable {
    public struct Bucket: Codable, Sendable, Hashable {
        /// Lower bound in seconds.
        public var start: Double
        /// Upper bound in seconds.
        public var end: Double
        public var count: Int

        public init(start: Double, end: Double, count: Int) {
            self.start = start
            self.end = end
            self.count = count
        }

        var midpoint: Double { (start + end) / 2 }
    }

    /// Buckets sorted by `start`.
    public var buckets: [Bucket]

    public init(buckets: [Bucket]) {
        self.buckets = buckets.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The number of samples across every bucket.
    public var sampleCount: Int { buckets.reduce(0) { $0 + $1.count } }

    /// Estimated sum of all samples, in seconds.
    public var estimatedTotal: Double { buckets.reduce(0) { $0 + $1.midpoint * Double($1.count) } }

    /// Estimated mean, or `nil` when there are no samples.
    public var estimatedMean: Double? {
        let count = sampleCount
        return count > 0 ? estimatedTotal / Double(count) : nil
    }

    /// The upper bound of the highest bucket that has samples: no sample was
    /// longer than this.
    public var upperBound: Double? { buckets.last { $0.count > 0 }?.end }

    /// The upper bound of the bucket holding the `fraction` quantile, e.g.
    /// `0.5` for the median or `0.95` for p95. `nil` when there are no samples.
    public func estimatedQuantile(_ fraction: Double) -> Double? {
        let count = sampleCount
        guard count > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        // The rank (1-based) of the sample at this quantile.
        let rank = max(1, Int((clamped * Double(count)).rounded(.up)))
        var seen = 0
        for bucket in buckets where bucket.count > 0 {
            seen += bucket.count
            if seen >= rank { return bucket.end }
        }
        return upperBound
    }

    /// Adds `other`'s counts into this histogram, matching buckets by their
    /// bounds. MetricKit reuses the same bucket edges across payloads, so
    /// this rolls several days up into one distribution.
    public func merged(with other: DurationHistogram) -> DurationHistogram {
        var counts: [BucketKey: Int] = [:]
        for bucket in buckets + other.buckets {
            counts[BucketKey(bucket), default: 0] += bucket.count
        }
        return DurationHistogram(
            buckets: counts.map { Bucket(start: $0.key.start, end: $0.key.end, count: $0.value) }
        )
    }

    private struct BucketKey: Hashable {
        let start: Double
        let end: Double
        init(_ bucket: Bucket) {
            start = bucket.start
            end = bucket.end
        }
    }
}

// MARK: - Metric payloads

/// Process exits MetricKit counted in one payload period (`MXAppExitMetric`).
public struct AppExitCounts: Codable, Sendable, Hashable {
    public var normal = 0
    public var memoryResourceLimit = 0
    public var badAccess = 0
    public var abnormal = 0
    public var illegalInstruction = 0
    public var watchdog = 0
    /// Background only.
    public var cpuResourceLimit = 0
    /// Background only: jetsam under memory pressure.
    public var memoryPressure = 0
    /// Background only.
    public var suspendedWithLockedFile = 0
    /// Background only.
    public var backgroundTaskAssertionTimeout = 0

    public init(
        normal: Int = 0,
        memoryResourceLimit: Int = 0,
        badAccess: Int = 0,
        abnormal: Int = 0,
        illegalInstruction: Int = 0,
        watchdog: Int = 0,
        cpuResourceLimit: Int = 0,
        memoryPressure: Int = 0,
        suspendedWithLockedFile: Int = 0,
        backgroundTaskAssertionTimeout: Int = 0
    ) {
        self.normal = normal
        self.memoryResourceLimit = memoryResourceLimit
        self.badAccess = badAccess
        self.abnormal = abnormal
        self.illegalInstruction = illegalInstruction
        self.watchdog = watchdog
        self.cpuResourceLimit = cpuResourceLimit
        self.memoryPressure = memoryPressure
        self.suspendedWithLockedFile = suspendedWithLockedFile
        self.backgroundTaskAssertionTimeout = backgroundTaskAssertionTimeout
    }

    /// Every exit that wasn't a normal one: crashes, watchdog kills and
    /// resource-limit terminations.
    public var unexpected: Int {
        memoryResourceLimit + badAccess + abnormal + illegalInstruction + watchdog + cpuResourceLimit
            + memoryPressure + suspendedWithLockedFile + backgroundTaskAssertionTimeout
    }

    /// Exits caused by memory: the resource limit or memory pressure.
    public var memoryRelated: Int { memoryResourceLimit + memoryPressure }
}

/// One custom signpost interval as MetricKit aggregated it
/// (`MXSignpostMetric`). Blau emits these with `mxSignpost` for the
/// intervals marked `reportsToMetricKit` (see docs/performance.md).
public struct SignpostMetricSummary: Codable, Sendable, Hashable {
    public var category: String
    public var name: String
    public var totalCount: Int
    public var duration: DurationHistogram?
    public var cumulativeCPUSeconds: Double?
    public var averageMemoryBytes: Double?
    public var cumulativeLogicalWriteBytes: Double?

    public init(
        category: String,
        name: String,
        totalCount: Int,
        duration: DurationHistogram? = nil,
        cumulativeCPUSeconds: Double? = nil,
        averageMemoryBytes: Double? = nil,
        cumulativeLogicalWriteBytes: Double? = nil
    ) {
        self.category = category
        self.name = name
        self.totalCount = totalCount
        self.duration = duration
        self.cumulativeCPUSeconds = cumulativeCPUSeconds
        self.averageMemoryBytes = averageMemoryBytes
        self.cumulativeLogicalWriteBytes = cumulativeLogicalWriteBytes
    }
}

/// The parts of an `MXMetricPayload` the diagnostics screen uses.
public struct MetricPayloadSummary: Codable, Sendable, Hashable {
    public var periodStart: Date
    public var periodEnd: Date
    public var environment: PayloadEnvironment
    /// `latestApplicationVersion`: the newest app version in the period.
    public var latestAppVersion: String?
    public var includesMultipleAppVersions: Bool

    public var peakMemoryBytes: Double?
    public var averageSuspendedMemoryBytes: Double?
    public var cumulativeCPUSeconds: Double?
    public var cumulativeLogicalWriteBytes: Double?

    /// Main-thread hangs (`histogrammedApplicationHangTime`).
    public var hangTime: DurationHistogram?
    public var timeToFirstDraw: DurationHistogram?
    public var resumeTime: DurationHistogram?

    public var foregroundExits: AppExitCounts?
    public var backgroundExits: AppExitCounts?

    public var signposts: [SignpostMetricSummary]

    public init(
        periodStart: Date,
        periodEnd: Date,
        environment: PayloadEnvironment = PayloadEnvironment(),
        latestAppVersion: String? = nil,
        includesMultipleAppVersions: Bool = false,
        peakMemoryBytes: Double? = nil,
        averageSuspendedMemoryBytes: Double? = nil,
        cumulativeCPUSeconds: Double? = nil,
        cumulativeLogicalWriteBytes: Double? = nil,
        hangTime: DurationHistogram? = nil,
        timeToFirstDraw: DurationHistogram? = nil,
        resumeTime: DurationHistogram? = nil,
        foregroundExits: AppExitCounts? = nil,
        backgroundExits: AppExitCounts? = nil,
        signposts: [SignpostMetricSummary] = []
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.environment = environment
        self.latestAppVersion = latestAppVersion
        self.includesMultipleAppVersions = includesMultipleAppVersions
        self.peakMemoryBytes = peakMemoryBytes
        self.averageSuspendedMemoryBytes = averageSuspendedMemoryBytes
        self.cumulativeCPUSeconds = cumulativeCPUSeconds
        self.cumulativeLogicalWriteBytes = cumulativeLogicalWriteBytes
        self.hangTime = hangTime
        self.timeToFirstDraw = timeToFirstDraw
        self.resumeTime = resumeTime
        self.foregroundExits = foregroundExits
        self.backgroundExits = backgroundExits
        self.signposts = signposts
    }
}

// MARK: - Diagnostic payloads

/// One main-thread hang report (`MXHangDiagnostic`).
public struct HangEvent: Codable, Sendable, Hashable {
    public var durationSeconds: Double
    public var appVersion: String?

    public init(durationSeconds: Double, appVersion: String? = nil) {
        self.durationSeconds = durationSeconds
        self.appVersion = appVersion
    }
}

/// One crash report (`MXCrashDiagnostic`). Only codes and names are kept
/// here; the call stack and the exception's composed message stay in the raw
/// payload.
public struct CrashEvent: Codable, Sendable, Hashable {
    /// Mach exception type, e.g. 1 for `EXC_BAD_ACCESS`.
    public var exceptionType: Int?
    public var exceptionCode: Int64?
    /// POSIX signal, e.g. 11 for `SIGSEGV`.
    public var signal: Int?
    public var terminationReason: String?
    /// For an uncaught Objective-C exception, e.g. `NSInvalidArgumentException`.
    public var objectiveCExceptionName: String?
    public var appVersion: String?

    public init(
        exceptionType: Int? = nil,
        exceptionCode: Int64? = nil,
        signal: Int? = nil,
        terminationReason: String? = nil,
        objectiveCExceptionName: String? = nil,
        appVersion: String? = nil
    ) {
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
        self.objectiveCExceptionName = objectiveCExceptionName
        self.appVersion = appVersion
    }

    /// A short label such as `SIGSEGV` or `NSInvalidArgumentException`.
    public var label: String {
        if let objectiveCExceptionName { return objectiveCExceptionName }
        if let signal, let name = Self.signalNames[signal] { return name }
        if let signal { return "signal \(signal)" }
        if let exceptionType { return "exception type \(exceptionType)" }
        return "crash"
    }

    private static let signalNames: [Int: String] = [
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
        11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
    ]
}

/// A CPU-usage exception (`MXCPUExceptionDiagnostic`).
public struct CPUExceptionEvent: Codable, Sendable, Hashable {
    public var totalCPUSeconds: Double
    public var totalSampledSeconds: Double

    public init(totalCPUSeconds: Double, totalSampledSeconds: Double) {
        self.totalCPUSeconds = totalCPUSeconds
        self.totalSampledSeconds = totalSampledSeconds
    }
}

/// A disk-write exception (`MXDiskWriteExceptionDiagnostic`).
public struct DiskWriteExceptionEvent: Codable, Sendable, Hashable {
    public var totalWriteBytes: Double

    public init(totalWriteBytes: Double) {
        self.totalWriteBytes = totalWriteBytes
    }
}

/// The parts of an `MXDiagnosticPayload` the diagnostics screen uses.
public struct DiagnosticPayloadSummary: Codable, Sendable, Hashable {
    public var periodStart: Date
    public var periodEnd: Date
    /// From the first diagnostic in the payload.
    public var environment: PayloadEnvironment
    public var hangs: [HangEvent]
    public var crashes: [CrashEvent]
    public var cpuExceptions: [CPUExceptionEvent]
    public var diskWriteExceptions: [DiskWriteExceptionEvent]
    /// Slow launches (`MXAppLaunchDiagnostic`, iOS only), in seconds.
    public var slowLaunchSeconds: [Double]

    public init(
        periodStart: Date,
        periodEnd: Date,
        environment: PayloadEnvironment = PayloadEnvironment(),
        hangs: [HangEvent] = [],
        crashes: [CrashEvent] = [],
        cpuExceptions: [CPUExceptionEvent] = [],
        diskWriteExceptions: [DiskWriteExceptionEvent] = [],
        slowLaunchSeconds: [Double] = []
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.environment = environment
        self.hangs = hangs
        self.crashes = crashes
        self.cpuExceptions = cpuExceptions
        self.diskWriteExceptions = diskWriteExceptions
        self.slowLaunchSeconds = slowLaunchSeconds
    }
}

// MARK: - Records

/// A summary of either kind of payload.
public enum PayloadSummary: Codable, Sendable, Hashable {
    case metrics(MetricPayloadSummary)
    case diagnostics(DiagnosticPayloadSummary)

    public var kind: DiagnosticsPayloadKind {
        switch self {
        case .metrics: .metrics
        case .diagnostics: .diagnostics
        }
    }

    public var periodStart: Date {
        switch self {
        case .metrics(let summary): summary.periodStart
        case .diagnostics(let summary): summary.periodStart
        }
    }

    public var periodEnd: Date {
        switch self {
        case .metrics(let summary): summary.periodEnd
        case .diagnostics(let summary): summary.periodEnd
        }
    }

    public var environment: PayloadEnvironment {
        switch self {
        case .metrics(let summary): summary.environment
        case .diagnostics(let summary): summary.environment
        }
    }
}

/// A payload handed to the store: MetricKit's JSON plus Blau's summary of it.
public struct CapturedPayload: Sendable, Hashable {
    /// `JSONRepresentation()` of the MetricKit payload, stored verbatim.
    public var json: Data
    public var summary: PayloadSummary

    public init(json: Data, summary: PayloadSummary) {
        self.json = json
        self.summary = summary
    }

    public var kind: DiagnosticsPayloadKind { summary.kind }
}

/// One stored payload, as listed by `DiagnosticsStoring.records()`.
public struct DiagnosticsRecord: Codable, Sendable, Hashable, Identifiable {
    /// Content hash of the raw JSON, so the same payload delivered twice
    /// (live and again through `pastPayloads`) is stored once.
    public var id: String
    public var receivedAt: Date
    public var summary: PayloadSummary

    public init(id: String, receivedAt: Date, summary: PayloadSummary) {
        self.id = id
        self.receivedAt = receivedAt
        self.summary = summary
    }

    public var kind: DiagnosticsPayloadKind { summary.kind }
}
