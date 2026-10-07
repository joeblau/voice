import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Testing

@testable import Blau

/// The degraded-mode indicator and the composition root's wiring of the
/// thermal and power policy (#75).
@MainActor
struct PerformanceIndicatorTests {
    @Test func nothingShowsAtNormal() {
        #expect(PerformanceIndicatorContent(PerformanceSnapshot()) == nil)
    }

    @Test func theIndicatorNamesTheCause() throws {
        let hot = try #require(
            PerformanceIndicatorContent(
                PerformanceSnapshot(
                    level: .reduced, reasons: [.thermal(.serious)],
                    conditions: DeviceConditions(thermalState: .serious))))
        #expect(hot.title == "Cooling down")
        #expect(hot.systemImage == "thermometer.medium")
        #expect(hot.accessibilityLabel.contains("warm"))
        #expect(hot.accessibilityLabel.contains("less often"))

        let battery = try #require(
            PerformanceIndicatorContent(PerformanceSnapshot(level: .minimal, reasons: [.lowBattery(percent: 8)])))
        #expect(battery.title == "Saving battery")
        #expect(battery.accessibilityLabel.contains("8 percent"))
        #expect(battery.accessibilityLabel.contains("paused"))

        let lowPower = try #require(
            PerformanceIndicatorContent(PerformanceSnapshot(level: .reduced, reasons: [.lowPowerMode])))
        #expect(lowPower.title == "Low Power Mode")

        let simulated = try #require(
            PerformanceIndicatorContent(PerformanceSnapshot(level: .reduced, reasons: [.override])))
        #expect(simulated.title == "Saving power")
    }

    @Test func theStatusFollowsThePolicy() async throws {
        let policy = PerformancePolicy(source: ManualDeviceConditionsSource(), signposter: .disabled(.performance))
        let status = PerformanceStatus(policy: policy)
        status.start()
        #expect(status.indicator == nil)

        policy.update(DeviceConditions(isLowPowerModeEnabled: true))
        try await waitFor { status.snapshot.level == .reduced }
        #expect(status.indicator?.title == "Low Power Mode")

        policy.setOverride(.normal)
        try await waitFor { status.indicator == nil }
    }

    @Test func fakeEnvironmentsRunAtNormalAndFeedTheInferenceMonitor() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(environment.performance.performanceLevel == .normal)
        #expect(environment.performanceStatus.snapshot.level == .normal)

        await environment.start()
        environment.performance.setOverride(.minimal)
        try await waitFor { await environment.backgroundInference.performanceLevel == .minimal }
        try await waitFor { environment.performanceStatus.snapshot.level == .minimal }
        environment.performance.setOverride(nil)
        try await waitFor { await environment.backgroundInference.performanceLevel == .normal }
    }

    /// The voice loop builds the live transcriber with the environment's
    /// policy (`LiveVoicePipeline.start` → `PerformanceASRChunkSizePolicy`),
    /// so the ASR chunk size follows the level in every environment,
    /// the live one included.
    @Test func theVoiceLoopFollowsTheEnvironmentsPolicy() throws {
        let environments = [
            AppEnvironment.fake(kind: .unitTest),
            AppEnvironment.live(config: .fallback, persistence: .inMemory()),
        ]
        for environment in environments {
            let forwarded = try #require(environment.voiceLoop.performance as? PerformancePolicy)
            #expect(forwarded === environment.performance)

            // Overrides, so the live policy doesn't depend on the host's
            // battery or Low Power Mode.
            let chunkSize = PerformanceASRChunkSizePolicy(environment.voiceLoop.performance)
            environment.performance.setOverride(.normal)
            #expect(chunkSize.preferredChunkSize(current: .ms320) == .ms320)
            environment.performance.setOverride(.reduced)
            #expect(chunkSize.preferredChunkSize(current: .ms320) == .ms1280)
            environment.performance.setOverride(nil)
        }
    }

    private func waitFor(
        timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
