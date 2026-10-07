import BlauTelemetry
import Foundation

/// The bar a Parakeet EOU chunk size must clear on every measured iPhone to
/// be Blau's default. See "EOU-320 go/no-go" in docs/benchmarks.md.
///
/// The 320 ms hop is the budget for everything that runs per hop on device:
/// ASR, VAD and voice ID share it, so ASR gets at most half.
public struct EouChunkSizeCriteria: Codable, Hashable, Sendable {
    /// Paced per-window p95 latency, as a share of the hop (`0.5` = half).
    public var maximumWindowP95OfHop: Double
    /// Burst real-time factor. At 4× the model is busy at most a quarter of
    /// the time, which keeps a one-hour session out of thermal trouble.
    public var minimumRealTimeFactor: Double
    /// Footprint growth while loading and running, in megabytes.
    public var maximumFootprintGrowthMegabytes: Double
    /// Distinct physical iPhones that must have reported.
    public var minimumDevices: Int

    public init(
        maximumWindowP95OfHop: Double = 0.5,
        minimumRealTimeFactor: Double = 4,
        maximumFootprintGrowthMegabytes: Double = 300,
        minimumDevices: Int = 2
    ) {
        self.maximumWindowP95OfHop = maximumWindowP95OfHop
        self.minimumRealTimeFactor = minimumRealTimeFactor
        self.maximumFootprintGrowthMegabytes = maximumFootprintGrowthMegabytes
        self.minimumDevices = minimumDevices
    }
}

/// Go, no-go, or not enough data yet.
public enum EouChunkSizeVerdict: Hashable, Sendable {
    /// Every qualifying device met every criterion.
    case go(devices: [String])
    /// At least one device missed a criterion.
    case noGo(reasons: [String])
    /// Too few qualifying reports to decide.
    case pending(reason: String)
}

/// Decides whether a Parakeet EOU chunk size can be the default, from
/// benchmark reports.
///
/// Only Release runs on physical iPhones that stayed below `serious`
/// thermal state count. When a device has several qualifying reports, the
/// most recent one is used.
public enum EouChunkSizeDecision {
    public static func evaluate(
        _ chunkSize: ParakeetEouChunkSize = .ms320,
        reports: [BenchmarkReport],
        criteria: EouChunkSizeCriteria = EouChunkSizeCriteria()
    ) -> EouChunkSizeVerdict {
        var latest: [String: (report: BenchmarkReport, result: BenchmarkResult)] = [:]
        var excluded: [String] = []
        for report in reports.sorted(by: { $0.startedAt < $1.startedAt }) {
            let device = report.device
            guard let result = report.result(chunkSize.benchmarkID) else { continue }
            if device.isSimulator || !device.operatingSystem.hasPrefix("iOS") {
                excluded.append("\(device.displayName): not a physical iPhone")
            } else if report.buildConfiguration != "Release" {
                excluded.append("\(device.displayName): \(report.buildConfiguration ?? "unknown") build")
            } else if !result.outcome.isCompleted {
                excluded.append("\(device.displayName): \(result.outcome)")
            } else if result.wasThrottled {
                excluded.append("\(device.displayName): thermally throttled")
            } else {
                latest[device.modelIdentifier] = (report, result)
            }
        }

        var reasons: [String] = []
        for (_, entry) in latest.sorted(by: { $0.key < $1.key }) {
            reasons += failures(of: entry.result, on: entry.report.device, criteria: criteria)
        }
        if !reasons.isEmpty {
            return .noGo(reasons: reasons)
        }
        guard latest.count >= criteria.minimumDevices else {
            var reason = "\(latest.count) of \(criteria.minimumDevices) iPhones reported qualifying results"
            if !excluded.isEmpty {
                reason += " (excluded: \(excluded.joined(separator: "; ")))"
            }
            return .pending(reason: reason)
        }
        return .go(devices: latest.values.map(\.report.device.displayName).sorted())
    }

    static func failures(
        of result: BenchmarkResult,
        on device: BenchmarkDevice,
        criteria: EouChunkSizeCriteria
    ) -> [String] {
        var failures: [String] = []
        let name = device.displayName

        if let share = result.metric("window.p95OfHop")?.value {
            let limit = criteria.maximumWindowP95OfHop * 100
            if share > limit {
                failures.append("\(name): window p95 is \(Int(share.rounded()))% of the hop (limit \(Int(limit))%)")
            }
        } else {
            failures.append("\(name): no paced window latency")
        }

        if let rtfx = result.metric("rtfx")?.value {
            if rtfx < criteria.minimumRealTimeFactor {
                failures.append(
                    "\(name): RTFx \(rtfx.formatted(.number.precision(.fractionLength(1)))) "
                        + "(minimum \(criteria.minimumRealTimeFactor.formatted()))")
            }
        } else {
            failures.append("\(name): no RTFx")
        }

        if let growth = result.metric("memory.footprintGrowth")?.value,
            growth > criteria.maximumFootprintGrowthMegabytes
        {
            failures.append(
                "\(name): footprint grew \(Int(growth.rounded())) MB "
                    + "(limit \(Int(criteria.maximumFootprintGrowthMegabytes)) MB)")
        }
        return failures
    }
}
