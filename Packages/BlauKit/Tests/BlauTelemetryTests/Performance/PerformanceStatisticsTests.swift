import BlauTelemetry
import Foundation
import Testing

/// The session statistics soak reports use to check the thermal criterion
/// (#75).
@Suite("Performance statistics")
struct PerformanceStatisticsTests {
    static func snapshot(
        _ level: PerformanceLevel, _ thermal: ThermalState = .nominal, battery: Double? = nil,
        charging: Bool = false, lowPower: Bool = false
    ) -> PerformanceSnapshot {
        PerformanceSnapshot(
            level: level,
            reasons: level.isDegraded ? [.thermal(thermal)] : [],
            conditions: DeviceConditions(
                thermalState: thermal, isLowPowerModeEnabled: lowPower,
                battery: battery.map { BatteryStatus(level: $0, state: charging ? .charging : .unplugged) }
                    ?? .unknown))
    }

    @Test func accumulatesTimeAtEachLevelAndThermalState() {
        var recorder = PerformanceStatisticsRecorder(start: .seconds(100))
        recorder.record(Self.snapshot(.normal, .nominal), at: .seconds(100))
        recorder.record(Self.snapshot(.normal, .fair), at: .seconds(1_300))
        recorder.record(Self.snapshot(.reduced, .serious), at: .seconds(2_500))
        recorder.record(Self.snapshot(.reduced, .fair), at: .seconds(2_800))
        recorder.record(Self.snapshot(.normal, .fair), at: .seconds(2_860))
        let statistics = recorder.statistics(at: .seconds(3_700))

        #expect(statistics.seconds == 3_600)
        #expect(statistics.seconds(at: .normal) == 1_200 + 1_200 + 840)
        #expect(statistics.seconds(at: .reduced) == 360)
        #expect(statistics.seconds(at: .minimal) == 0)
        #expect(statistics.seconds(at: .nominal) == 1_200)
        #expect(statistics.seconds(at: .fair) == 1_200 + 60 + 840)
        #expect(statistics.seconds(at: .serious) == 300)
        #expect(statistics.secondsAtOrBelowFair == 3_300)
        #expect(statistics.worstThermalState == .serious)
        #expect(statistics.worstLevel == .reduced)
        #expect(statistics.levelChanges == 2)
        #expect(statistics.secondsHotAtNormal == 0, "it degraded the moment it got hot")
        #expect(statistics.transitions.map(\.to) == [.reduced, .normal])
        #expect(statistics.transitions.first?.atSeconds == 2_400)
        #expect(statistics.transitions.first?.thermalState == .serious)
    }

    @Test func countsHeatThePipelineDidNotReactTo() {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        recorder.record(Self.snapshot(.normal, .serious), at: .zero)
        recorder.record(Self.snapshot(.reduced, .serious), at: .seconds(45))
        #expect(recorder.statistics(at: .seconds(60)).secondsHotAtNormal == 45)
    }

    @Test func measuresBatteryDrainOnlyWhileDischarging() throws {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        recorder.record(Self.snapshot(.normal, battery: 0.90), at: .zero)
        recorder.record(Self.snapshot(.normal, battery: 0.85), at: .seconds(1_800))
        recorder.record(Self.snapshot(.normal, battery: 0.86, charging: true), at: .seconds(2_000))
        recorder.record(Self.snapshot(.normal, battery: 0.95, charging: true), at: .seconds(2_600))
        recorder.record(Self.snapshot(.normal, battery: 0.95), at: .seconds(2_600))
        recorder.record(Self.snapshot(.normal, battery: 0.90), at: .seconds(4_400))
        let statistics = recorder.statistics(at: .seconds(4_400))

        #expect(statistics.batteryAtStart == 0.90)
        #expect(statistics.batteryAtEnd == 0.90)
        #expect(abs(statistics.batteryDrained - 0.10) < 1e-9)
        #expect(statistics.dischargingSeconds == 3_800)
        let perHour = try #require(statistics.batteryDrainPercentPerHour)
        #expect(abs(perHour - 10 / (3_800.0 / 3_600)) < 1e-6)
    }

    @Test func drainNeedsAMinuteOnBattery() {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        recorder.record(Self.snapshot(.normal, battery: 0.5), at: .zero)
        #expect(recorder.statistics(at: .seconds(30)).batteryDrainPercentPerHour == nil)
    }

    @Test func countsLowPowerModeTime() {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        recorder.record(Self.snapshot(.reduced, lowPower: true), at: .zero)
        recorder.record(Self.snapshot(.normal), at: .seconds(120))
        #expect(recorder.statistics(at: .seconds(200)).lowPowerModeSeconds == 120)
    }

    @Test func keepsTheLatestTransitions() {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        for second in 0..<250 {
            recorder.record(Self.snapshot(second.isMultiple(of: 2) ? .normal : .reduced), at: .seconds(second))
        }
        let statistics = recorder.statistics(at: .seconds(250))
        #expect(statistics.levelChanges == 249)
        #expect(statistics.transitions.count == PerformanceStatistics.transitionLimit)
        #expect(statistics.transitions.last?.atSeconds == 249)
    }

    @Test func roundTripsThroughJSON() throws {
        var recorder = PerformanceStatisticsRecorder(start: .zero)
        recorder.record(Self.snapshot(.normal, battery: 0.7), at: .zero)
        recorder.record(Self.snapshot(.minimal, .critical, battery: 0.6), at: .seconds(90))
        let statistics = recorder.statistics(at: .seconds(100))
        let decoded = try JSONDecoder().decode(
            PerformanceStatistics.self, from: JSONEncoder().encode(statistics))
        #expect(decoded == statistics)
    }
}
