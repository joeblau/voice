import Foundation
import Synchronization

/// The device's thermal pressure, as `ProcessInfo.thermalState` reports it.
public enum DeviceThermalState: String, Sendable, Hashable, CaseIterable, Codable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    /// The current state of this device.
    public static var current: DeviceThermalState {
        DeviceThermalState(ProcessInfo.processInfo.thermalState)
    }

    /// Whether the system is likely throttling (serious or critical).
    public var isThrottling: Bool { self == .serious || self == .critical }
}

/// Latest values that pipeline stages publish for the performance HUD when
/// the HUD has no other way to reach them: the voice ID gate's score (#47)
/// and the topic segmenter's depth score (#52).
///
/// Reporting is one short lock and never allocates, so a stage may report
/// on every decision whether or not the HUD is showing.
///
/// ```swift
/// PerformanceGauges.shared.report(.voiceScore, Double(score))
/// ```
public final class PerformanceGauges: Sendable {
    /// The gauges the shared pipeline stages report to.
    public static let shared = PerformanceGauges()

    public enum Gauge: Int, Sendable, Hashable, CaseIterable {
        /// The voice ID gate's latest segment score (cosine after AS-norm).
        case voiceScore
        /// The voice ID gate's acceptance threshold for that score.
        case voiceThreshold
        /// The topic segmenter's depth score at the newest scored gap.
        case topicDepth
        /// The segmenter's current entry threshold for a boundary.
        case topicThreshold
    }

    /// One reported value.
    public struct Reading: Sendable, Hashable {
        public var value: Double
        /// When it was reported (continuous clock, nanoseconds).
        public var reportedAt: UInt64
        /// Reports of this gauge so far.
        public var count: Int

        public init(value: Double, reportedAt: UInt64, count: Int) {
            self.value = value
            self.reportedAt = reportedAt
            self.count = count
        }
    }

    private let readings = Mutex<[Reading?]>(Array(repeating: nil, count: Gauge.allCases.count))

    public init() {}

    /// Publishes `value` for `gauge`. Non-finite values are ignored.
    public func report(_ gauge: Gauge, _ value: Double) {
        guard value.isFinite else { return }
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        readings.withLock { readings in
            let count = (readings[gauge.rawValue]?.count ?? 0) + 1
            readings[gauge.rawValue] = Reading(value: value, reportedAt: now, count: count)
        }
    }

    /// Forgets `gauge`'s value, e.g. when a conversation ends.
    public func clear(_ gauge: Gauge) {
        readings.withLock { $0[gauge.rawValue] = nil }
    }

    /// The latest value of `gauge`, or `nil` if none was reported.
    public func reading(_ gauge: Gauge) -> Reading? {
        readings.withLock { $0[gauge.rawValue] }
    }
}
