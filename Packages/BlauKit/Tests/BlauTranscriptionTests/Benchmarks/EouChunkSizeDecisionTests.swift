import BlauTelemetry
import BlauTranscription
import Foundation
import Testing

@Suite("EOU chunk size go/no-go")
struct EouChunkSizeDecisionTests {
    static func report(
        _ identifier: String,
        p95OfHop: Double? = 30,
        rtfx: Double? = 12,
        growthMB: Double = 150,
        outcome: BenchmarkResult.Outcome = .completed,
        build: String? = "Release",
        simulator: Bool = false,
        thermal: ThermalState = .nominal,
        at time: TimeInterval = 0,
        operatingSystem: String = "iOS 27.2 (Build 24C5054e)"
    ) -> BenchmarkReport {
        var metrics = [BenchmarkMetric(key: "memory.footprintGrowth", value: growthMB, unit: .megabytes)]
        if let p95OfHop { metrics.append(BenchmarkMetric(key: "window.p95OfHop", value: p95OfHop, unit: .percent)) }
        if let rtfx { metrics.append(BenchmarkMetric(key: "rtfx", value: rtfx, unit: .realTimeFactor)) }
        let result = BenchmarkResult(
            id: "asr.eou.320ms", title: "EOU 320", outcome: outcome, metrics: metrics, latencies: [:], notes: [],
            startedAt: Date(timeIntervalSince1970: time), wallTimeSeconds: 90, thermalStateAtStart: .nominal,
            thermalStateAtEnd: thermal)
        return BenchmarkReport(
            device: .fixture(identifier: identifier, simulator: simulator, operatingSystem: operatingSystem),
            startedAt: Date(timeIntervalSince1970: time), results: [result], buildConfiguration: build)
    }

    @Test func twoPassingIPhonesAreAGo() {
        let verdict = EouChunkSizeDecision.evaluate(reports: [Self.report("iPhone16,1"), Self.report("iPhone17,1")])
        #expect(verdict == .go(devices: ["iPhone 15 Pro (A17 Pro)", "iPhone 16 Pro (A18 Pro)"]))
    }

    @Test func oneDeviceIsPending() {
        guard case .pending(let reason) = EouChunkSizeDecision.evaluate(reports: [Self.report("iPhone16,1")]) else {
            Issue.record("Expected pending")
            return
        }
        #expect(reason.hasPrefix("1 of 2 iPhones"))
    }

    @Test func noReportsArePending() {
        #expect(
            EouChunkSizeDecision.evaluate(reports: []) == .pending(reason: "0 of 2 iPhones reported qualifying results")
        )
    }

    @Test func anyFailingDeviceIsANoGo() {
        let verdict = EouChunkSizeDecision.evaluate(reports: [
            Self.report("iPhone16,1", p95OfHop: 64, rtfx: 3.2, growthMB: 420),
            Self.report("iPhone17,1"),
        ])
        #expect(
            verdict
                == .noGo(reasons: [
                    "iPhone 15 Pro (A17 Pro): window p95 is 64% of the hop (limit 50%)",
                    "iPhone 15 Pro (A17 Pro): RTFx 3.2 (minimum 4)",
                    "iPhone 15 Pro (A17 Pro): footprint grew 420 MB (limit 300 MB)",
                ]))
    }

    @Test func missingMeasurementsAreFailures() {
        guard
            case .noGo(let reasons) = EouChunkSizeDecision.evaluate(reports: [
                Self.report("iPhone16,1", p95OfHop: nil, rtfx: nil), Self.report("iPhone17,1"),
            ])
        else {
            Issue.record("Expected no-go")
            return
        }
        #expect(reasons.count == 2)
    }

    @Test func onlyReleaseRunsOnCoolPhysicalIPhonesCount() {
        let verdict = EouChunkSizeDecision.evaluate(reports: [
            Self.report("iPhone17,1", p95OfHop: 90, simulator: true),
            Self.report("iPhone17,3", p95OfHop: 90, build: "Debug"),
            Self.report("iPhone18,1", p95OfHop: 90, thermal: .serious),
            Self.report("Mac15,6", p95OfHop: 90, operatingSystem: "macOS 27.2"),
            Self.report("iPhone16,1", outcome: .failed(message: "boom")),
            Self.report("iPhone16,2"),
        ])
        guard case .pending(let reason) = verdict else {
            Issue.record("Expected pending, got \(verdict)")
            return
        }
        #expect(reason.contains("1 of 2"))
        #expect(reason.contains("Debug build"))
        #expect(reason.contains("thermally throttled"))
        #expect(reason.contains("not a physical iPhone"))
    }

    @Test func theLatestRunPerDeviceWins() {
        let verdict = EouChunkSizeDecision.evaluate(reports: [
            Self.report("iPhone16,1", p95OfHop: 90, at: 0),
            Self.report("iPhone16,1", p95OfHop: 30, at: 100),
            Self.report("iPhone17,1", at: 50),
        ])
        #expect(verdict == .go(devices: ["iPhone 15 Pro (A17 Pro)", "iPhone 16 Pro (A18 Pro)"]))
    }

    @Test func criteriaCanBeTightened() {
        let strict = EouChunkSizeCriteria(minimumRealTimeFactor: 20)
        guard
            case .noGo = EouChunkSizeDecision.evaluate(
                reports: [Self.report("iPhone16,1"), Self.report("iPhone17,1")], criteria: strict)
        else {
            Issue.record("Expected no-go")
            return
        }
    }
}
