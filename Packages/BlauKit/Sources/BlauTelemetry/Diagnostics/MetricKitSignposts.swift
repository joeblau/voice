import Synchronization
import os

#if canImport(MetricKit)
    import MetricKit
#endif

/// Emits the MetricKit half of a signpost interval.
///
/// MetricKit only aggregates intervals emitted with `mxSignpost` on a log
/// handle from `MXMetricManager.makeLogHandle(category:)`; ordinary
/// `os_signpost` intervals never reach `MXMetricPayload.signpostMetrics`.
/// The seam lets tests check what would be sent without MetricKit.
public protocol MetricSignpostEmitter: Sendable {
    /// Whether the MetricKit log handle is recording signposts.
    var isEnabled: Bool { get }
    func beginInterval(_ name: StaticString, id: UInt64)
    func endInterval(_ name: StaticString, id: UInt64)
}

#if canImport(MetricKit)
    /// Emits `mxSignpost` intervals on a MetricKit log handle, so MetricKit
    /// reports their count, duration histogram, CPU time, memory and disk
    /// writes in the daily metric payload.
    public struct MXSignpostEmitter: MetricSignpostEmitter {
        public let log: OSLog

        /// A MetricKit log handle for `category`. The category becomes
        /// `signpostCategory` in the payload, so it matches the `os_signpost`
        /// category Instruments shows.
        public init(category: LogCategory) {
            log = MXMetricManager.makeLogHandle(category: category.rawValue)
        }

        public var isEnabled: Bool { log.signpostsEnabled }

        public func beginInterval(_ name: StaticString, id: UInt64) {
            mxSignpost(.begin, log: log, name: name, signpostID: OSSignpostID(id))
        }

        public func endInterval(_ name: StaticString, id: UInt64) {
            mxSignpost(.end, log: log, name: name, signpostID: OSSignpostID(id))
        }
    }
#endif

/// A `SignpostBackend` that sends every interval to `base` (Instruments) and
/// additionally reports a short list of key intervals to MetricKit.
///
/// MetricKit keeps a limited number of custom signpost metrics and every
/// `mxSignpost` captures a resource snapshot, so only the intervals marked
/// `PipelineInterval.reportsToMetricKit` go there: low-frequency spans the
/// user feels, such as `realtime.firstAudio`. Per-chunk intervals
/// (`capture.frame`, `asr.chunk`, ...) stay Instruments-only.
public final class MetricKitSignpostBackend: SignpostBackend {
    public let base: any SignpostBackend
    public let emitter: any MetricSignpostEmitter
    /// Names of the intervals reported to MetricKit.
    public let reportedIntervals: [StaticString]
    private let nextID = Atomic<UInt64>(1)

    public init(base: any SignpostBackend, emitter: any MetricSignpostEmitter, reportedIntervals: [StaticString]) {
        self.base = base
        self.emitter = emitter
        self.reportedIntervals = reportedIntervals
    }

    public var isEnabled: Bool { base.isEnabled || (!reportedIntervals.isEmpty && emitter.isEnabled) }

    /// Whether `name` is reported to MetricKit. Compares the bytes, so an
    /// ad-hoc literal with a canonical name counts too.
    public func reportsToMetricKit(_ name: StaticString) -> Bool {
        reportedIntervals.contains { Self.equal($0, name) }
    }

    public func beginInterval(_ name: StaticString) -> SignpostIntervalToken {
        let baseActive = base.isEnabled
        var token = baseActive ? base.beginInterval(name) : SignpostIntervalToken(id: 0)
        token.baseActive = baseActive
        if reportsToMetricKit(name), emitter.isEnabled {
            let id = nextID.wrappingAdd(1, ordering: .relaxed).oldValue
            emitter.beginInterval(name, id: id)
            token.metricKitID = id
        }
        return token
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken) {
        if token.baseActive {
            base.endInterval(name, token)
        }
        if let id = token.metricKitID {
            emitter.endInterval(name, id: id)
        }
    }

    /// The message goes to `base` only: `mxSignpost` intervals carry no end
    /// message, and MetricKit aggregates by name.
    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String) {
        if token.baseActive {
            base.endInterval(name, token, message: message)
        }
        if let id = token.metricKitID {
            emitter.endInterval(name, id: id)
        }
    }

    /// Events go to `base` only: MetricKit aggregates intervals, not events.
    public func emitEvent(_ name: StaticString) {
        guard base.isEnabled else { return }
        base.emitEvent(name)
    }

    private static func equal(_ lhs: StaticString, _ rhs: StaticString) -> Bool {
        lhs.withUTF8Buffer { lhs in rhs.withUTF8Buffer { rhs in lhs.elementsEqual(rhs) } }
    }
}

extension PipelineInterval {
    /// Whether this interval is also emitted with `mxSignpost`, so MetricKit
    /// reports it from real use (TestFlight included). Keep this list short
    /// and low frequency; docs/performance.md lists it and a test keeps the
    /// two in sync.
    public var reportsToMetricKit: Bool {
        switch self {
        case .asrEndOfUtterance, .voiceIDVerify, .realtimeTurn, .realtimeFirstAudio, .topicsLabel, .memorySearch:
            true
        case .captureFrame, .playbackFirstBuffer, .vadChunk, .asrChunk, .asrSecondPass, .modelDownload, .modelWarmUp,
            .voiceIDEmbed, .realtimeConnect, .realtimeEvent, .topicsSegment, .memoryEmbed, .memoryExtract,
            .memoryConsolidate, .dbSave, .sessionStart:
            false
        }
    }

    /// The intervals in `category` that are reported to MetricKit.
    public static func metricKitIntervals(in category: LogCategory) -> [PipelineInterval] {
        allCases.filter { $0.category == category && $0.reportsToMetricKit }
    }
}

extension Signposts {
    /// The backend behind the shared signposter for `category`: real
    /// `os_signpost` records, plus `mxSignpost` for the category's
    /// MetricKit intervals where MetricKit exists.
    public static func defaultBackend(for category: LogCategory) -> any SignpostBackend {
        let base = OSSignpostBackend(category: category)
        #if canImport(MetricKit)
            let reported = PipelineInterval.metricKitIntervals(in: category).map(\.name)
            if !reported.isEmpty {
                return MetricKitSignpostBackend(
                    base: base, emitter: MXSignpostEmitter(category: category), reportedIntervals: reported)
            }
        #endif
        return base
    }
}
