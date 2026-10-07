import BlauTelemetry
import Testing

/// The thermal and power policy's decision table and hysteresis (#75).
@Suite("Performance level tracker")
struct PerformanceLevelTrackerTests {
    static func battery(_ level: Double, _ state: BatteryStatus.State = .unplugged) -> DeviceConditions {
        DeviceConditions(battery: BatteryStatus(level: level, state: state))
    }

    static func assess(_ conditions: DeviceConditions, current: PerformanceLevel = .normal) -> PerformanceAssessment {
        PerformancePolicyConfiguration.standard.assess(conditions, current: current)
    }

    // MARK: The decision table

    @Test(
        "Thermal state alone",
        arguments: [
            (ThermalState.nominal, PerformanceLevel.normal),
            (.fair, .normal),
            (.serious, .reduced),
            (.critical, .minimal),
        ])
    func thermalState(_ state: ThermalState, expected: PerformanceLevel) {
        let assessment = Self.assess(DeviceConditions(thermalState: state))
        #expect(assessment.level == expected)
        #expect(assessment.reasons == (expected == .normal ? [] : [.thermal(state)]))
    }

    @Test func lowPowerModeReduces() {
        let assessment = Self.assess(DeviceConditions(isLowPowerModeEnabled: true))
        #expect(assessment == PerformanceAssessment(level: .reduced, reasons: [.lowPowerMode]))
    }

    @Test func lowPowerModeCanBeIgnored() {
        let configuration = PerformancePolicyConfiguration(lowPowerModeLevel: .normal)
        let assessment = configuration.assess(DeviceConditions(isLowPowerModeEnabled: true), current: .normal)
        #expect(assessment.level == .normal)
        #expect(assessment.reasons.isEmpty)
    }

    @Test(
        "Battery on discharge",
        arguments: [
            (0.80, PerformanceLevel.normal),
            (0.21, .normal),
            (0.20, .reduced),
            (0.11, .reduced),
            (0.10, .minimal),
            (0.02, .minimal),
        ])
    func batteryOnDischarge(_ charge: Double, expected: PerformanceLevel) {
        #expect(Self.assess(Self.battery(charge)).level == expected)
    }

    @Test(arguments: [BatteryStatus.State.charging, .full, .unknown])
    func aLowBatteryOnMainsPowerDoesNotCount(_ state: BatteryStatus.State) {
        #expect(Self.assess(Self.battery(0.05, state)).level == .normal)
    }

    @Test func anUnknownChargeDoesNotCount() {
        let conditions = DeviceConditions(battery: BatteryStatus(level: nil, state: .unplugged))
        #expect(Self.assess(conditions).level == .normal)
    }

    @Test func batteryLevelsHoldUntilTheChargeClearsTheHysteresis() {
        // Entered at 20%: holds until 25%.
        #expect(Self.assess(Self.battery(0.22), current: .reduced).level == .reduced)
        #expect(Self.assess(Self.battery(0.25), current: .reduced).level == .normal)
        // Entered at 10%: holds until 15%, then still reduced until 25%.
        #expect(Self.assess(Self.battery(0.12), current: .minimal).level == .minimal)
        #expect(Self.assess(Self.battery(0.16), current: .minimal).level == .reduced)
        // Without a degraded level in force, 22% is fine.
        #expect(Self.assess(Self.battery(0.22), current: .normal).level == .normal)
    }

    @Test func theStrictestCauseWinsAndComesFirst() {
        let conditions = DeviceConditions(
            thermalState: .serious, isLowPowerModeEnabled: true,
            battery: BatteryStatus(level: 0.08, state: .unplugged))
        let assessment = Self.assess(conditions)
        #expect(assessment.level == .minimal)
        #expect(assessment.reasons.first == .lowBattery(percent: 8))
        #expect(Set(assessment.reasons) == [.lowBattery(percent: 8), .thermal(.serious), .lowPowerMode])
    }

    @Test func reasonsDescribeThemselvesForLogs() {
        #expect(PerformanceReason.thermal(.serious).description == "thermal state serious")
        #expect(PerformanceReason.lowPowerMode.description == "Low Power Mode")
        #expect(PerformanceReason.lowBattery(percent: 9).description == "battery at 9%")
        #expect(PerformanceReason.override.description == "override")
    }

    @Test func levelsAreOrdered() {
        #expect(PerformanceLevel.normal < .reduced)
        #expect(PerformanceLevel.reduced < .minimal)
        #expect(PerformanceLevel.allCases.sorted() == [.normal, .reduced, .minimal])
        #expect(!PerformanceLevel.normal.isDegraded)
        #expect(PerformanceLevel.reduced.isDegraded)
    }

    // MARK: Hysteresis over time

    @Test func aWorseLevelAppliesAtOnce() {
        var tracker = PerformanceLevelTracker()
        let changed1 = tracker.update(DeviceConditions(thermalState: .serious), at: .seconds(10))
        #expect(changed1)
        #expect(tracker.level == .reduced)
        #expect(tracker.reasons == [.thermal(.serious)])
        let changed2 = tracker.update(DeviceConditions(thermalState: .critical), at: .seconds(11))
        #expect(changed2)
        #expect(tracker.level == .minimal)
        #expect(tracker.recoveryDeadline == nil)
    }

    @Test func aBetterLevelWaitsForTheRecoveryDelay() {
        var tracker = PerformanceLevelTracker()
        tracker.update(DeviceConditions(thermalState: .serious), at: .zero)
        let changed3 = tracker.update(DeviceConditions(thermalState: .fair), at: .seconds(100))
        #expect(!changed3)
        #expect(tracker.level == .reduced)
        #expect(tracker.isRecovering)
        #expect(tracker.recoveryDeadline == .seconds(160))
        #expect(tracker.reasons == [.thermal(.serious)], "the cause stays until the level changes")

        let changed4 = tracker.evaluate(at: .seconds(159))

        #expect(!changed4)
        #expect(tracker.level == .reduced)
        let changed5 = tracker.evaluate(at: .seconds(160))
        #expect(changed5)
        #expect(tracker.level == .normal)
        #expect(tracker.reasons.isEmpty)
        #expect(!tracker.isRecovering)
    }

    @Test func recoveryStepsDownOneLevelAtATime() {
        var tracker = PerformanceLevelTracker()
        tracker.update(DeviceConditions(thermalState: .critical), at: .zero)
        tracker.update(DeviceConditions(thermalState: .nominal), at: .seconds(10))
        tracker.evaluate(at: .seconds(70))
        #expect(tracker.level == .reduced)
        #expect(tracker.recoveryDeadline == .seconds(130))
        tracker.evaluate(at: .seconds(129))
        #expect(tracker.level == .reduced)
        tracker.evaluate(at: .seconds(130))
        #expect(tracker.level == .normal)
    }

    @Test func recoveryStopsAtWhatConditionsStillCallFor() {
        var tracker = PerformanceLevelTracker()
        tracker.update(
            DeviceConditions(thermalState: .critical, isLowPowerModeEnabled: true), at: .zero)
        tracker.update(DeviceConditions(thermalState: .nominal, isLowPowerModeEnabled: true), at: .seconds(1))
        tracker.evaluate(at: .seconds(61))
        #expect(tracker.level == .reduced)
        #expect(tracker.reasons == [.lowPowerMode])
        #expect(!tracker.isRecovering)
    }

    /// A device hovering at the `serious` boundary doesn't flip the
    /// pipeline: each return to `serious` restarts the delay.
    @Test func flappingConditionsKeepTheWorseLevel() {
        var tracker = PerformanceLevelTracker()
        var changes = 0
        for minute in 0..<10 {
            let start = Duration.seconds(minute * 60)
            if tracker.update(DeviceConditions(thermalState: .serious), at: start) { changes += 1 }
            if tracker.update(DeviceConditions(thermalState: .fair), at: start + .seconds(30)) { changes += 1 }
            if tracker.evaluate(at: start + .seconds(59)) { changes += 1 }
        }
        #expect(changes == 1, "only the first escalation")
        #expect(tracker.level == .reduced)
    }

    @Test func aBatteryHoveringAtTwentyPercentDoesNotFlap() {
        var tracker = PerformanceLevelTracker()
        tracker.update(Self.battery(0.20), at: .zero)
        #expect(tracker.level == .reduced)
        tracker.update(Self.battery(0.21), at: .seconds(10))
        tracker.update(Self.battery(0.20), at: .seconds(20))
        tracker.evaluate(at: .seconds(500))
        #expect(tracker.level == .reduced)
        // Plugging in releases it (after the delay).
        tracker.update(Self.battery(0.21, .charging), at: .seconds(600))
        tracker.evaluate(at: .seconds(660))
        #expect(tracker.level == .normal)
    }

    // MARK: Override

    @Test func anOverrideWinsInBothDirectionsAndClearsAtOnce() {
        var tracker = PerformanceLevelTracker()
        tracker.update(DeviceConditions(thermalState: .serious), at: .zero)
        let changed6 = tracker.setOverride(.normal, at: .seconds(1))
        #expect(changed6)
        #expect(tracker.level == .normal)
        #expect(tracker.override == .normal)
        tracker.update(DeviceConditions(thermalState: .critical), at: .seconds(2))
        #expect(tracker.level == .normal, "the override holds whatever the readings")

        let changed7 = tracker.setOverride(.minimal, at: .seconds(3))

        #expect(changed7)
        #expect(tracker.reasons == [.override])

        let changed8 = tracker.setOverride(nil, at: .seconds(4))

        #expect(changed8)
        #expect(tracker.level == .minimal)
        #expect(tracker.reasons == [.thermal(.critical)])

        tracker.update(.nominal, at: .seconds(5))
        tracker.setOverride(.reduced, at: .seconds(6))
        tracker.setOverride(nil, at: .seconds(7))
        #expect(tracker.level == .normal, "leaving a simulation doesn't wait out the recovery delay")
    }
}
