import BlauTelemetry
import Testing

/// The thermal and power policy's decision table and hysteresis (#75).
@Suite("Performance level tracker")
struct PerformanceLevelTrackerTests {
    static func battery(_ level: Double, _ state: BatteryStatus.State = .unplugged) -> DeviceConditions {
        DeviceConditions(battery: BatteryStatus(level: level, state: state))
    }

    static func assess(
        _ conditions: DeviceConditions, currentBattery: PerformanceLevel = .normal
    ) -> PerformanceAssessment {
        PerformancePolicyConfiguration.standard.assess(conditions, currentBattery: currentBattery)
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
        let assessment = configuration.assess(DeviceConditions(isLowPowerModeEnabled: true), currentBattery: .normal)
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
        #expect(Self.assess(Self.battery(0.22), currentBattery: .reduced).level == .reduced)
        #expect(Self.assess(Self.battery(0.25), currentBattery: .reduced).level == .normal)
        // Entered at 10%: holds until 15%, then still reduced until 25%.
        #expect(Self.assess(Self.battery(0.12), currentBattery: .minimal).level == .minimal)
        #expect(Self.assess(Self.battery(0.16), currentBattery: .minimal).level == .reduced)
        // Unless the battery itself called for a degraded level, 22% is fine.
        #expect(Self.assess(Self.battery(0.22), currentBattery: .normal).level == .normal)
    }

    @Test func theBatteryLevelIsTheBatterysOwnCall() {
        let configuration = PerformancePolicyConfiguration.standard
        let low = BatteryStatus(level: 0.23, state: .unplugged)
        #expect(configuration.batteryLevel(for: low, current: .normal) == .normal)
        #expect(configuration.batteryLevel(for: low, current: .reduced) == .reduced)
        let veryLow = BatteryStatus(level: 0.12, state: .unplugged)
        #expect(configuration.batteryLevel(for: veryLow, current: .reduced) == .reduced)
        #expect(configuration.batteryLevel(for: veryLow, current: .minimal) == .minimal)
        let charging = BatteryStatus(level: 0.05, state: .charging)
        #expect(configuration.batteryLevel(for: charging, current: .minimal) == .normal)
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

    /// Heat at 21–24% on battery: the battery never crossed 20%, so it
    /// never holds the level once the device cools.
    @Test func heatDoesNotLendTheBatteryItsHysteresis() {
        var tracker = PerformanceLevelTracker()
        let battery = BatteryStatus(level: 0.23, state: .unplugged)
        tracker.update(DeviceConditions(thermalState: .serious, battery: battery), at: .zero)
        #expect(tracker.level == .reduced)
        #expect(tracker.reasons == [.thermal(.serious)])

        tracker.update(DeviceConditions(thermalState: .nominal, battery: battery), at: .seconds(1))
        #expect(tracker.level == .reduced, "still waiting out the recovery delay")
        #expect(tracker.reasons == [.thermal(.serious)])
        tracker.evaluate(at: .seconds(120))
        #expect(tracker.level == .normal)
        #expect(tracker.reasons.isEmpty)
    }

    @Test func lowPowerModeDoesNotLendTheBatteryItsHysteresis() {
        var tracker = PerformanceLevelTracker()
        let battery = BatteryStatus(level: 0.22, state: .unplugged)
        tracker.update(DeviceConditions(isLowPowerModeEnabled: true, battery: battery), at: .zero)
        #expect(tracker.reasons == [.lowPowerMode])

        tracker.update(DeviceConditions(isLowPowerModeEnabled: false, battery: battery), at: .seconds(1))
        tracker.evaluate(at: .seconds(120))
        #expect(tracker.level == .normal)
        #expect(tracker.reasons.isEmpty)
    }

    /// Critical heat at 11–14%: the battery alone calls for `reduced`
    /// there, so cooling relaxes to `reduced`, not `minimal`.
    @Test func criticalHeatDoesNotLendTheBatteryTheMinimalHysteresis() {
        var tracker = PerformanceLevelTracker()
        let battery = BatteryStatus(level: 0.12, state: .unplugged)
        tracker.update(DeviceConditions(thermalState: .critical, battery: battery), at: .zero)
        #expect(tracker.level == .minimal)
        #expect(tracker.reasons == [.thermal(.critical), .lowBattery(percent: 12)])

        tracker.update(DeviceConditions(thermalState: .nominal, battery: battery), at: .seconds(1))
        tracker.evaluate(at: .seconds(120))
        #expect(tracker.level == .reduced)
        #expect(tracker.reasons == [.lowBattery(percent: 12)])
        tracker.evaluate(at: .seconds(600))
        #expect(tracker.level == .reduced, "12% still calls for reduced on its own")
    }

    /// The battery keeps its own hysteresis when heat came and went in
    /// between.
    @Test func theBatteryKeepsItsOwnHysteresisThroughHeat() {
        var tracker = PerformanceLevelTracker()
        let entered = BatteryStatus(level: 0.19, state: .unplugged)
        tracker.update(DeviceConditions(thermalState: .serious, battery: entered), at: .zero)
        #expect(Set(tracker.reasons) == [.thermal(.serious), .lowBattery(percent: 19)])

        let bounced = BatteryStatus(level: 0.22, state: .unplugged)
        tracker.update(DeviceConditions(thermalState: .nominal, battery: bounced), at: .seconds(1))
        tracker.evaluate(at: .seconds(120))
        #expect(tracker.level == .reduced)
        #expect(tracker.reasons == [.lowBattery(percent: 22)])

        tracker.update(Self.battery(0.25), at: .seconds(130))
        tracker.evaluate(at: .seconds(200))
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
