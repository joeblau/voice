import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import Blau

/// The app side of the debug performance HUD (#71): when it shows, what it
/// remembers, and that it only measures while it runs. The readout, the
/// probes and the overhead budget are covered by `swift test` in BlauKit.
@Suite("Performance HUD", .serialized)
@MainActor
struct PerformanceHUDTests {
    private func controller(
        flags: FeatureFlags = .inMemory(),
        preferences: PerformanceHUDPreferences = .inMemory(),
        pipeline: @escaping @MainActor () -> PipelineReadings = { PipelineReadings() }
    ) -> PerformanceHUDController {
        PerformanceHUDController(
            flags: flags, preferences: preferences,
            sampler: PerformanceHUDSampler(tap: SignpostLatencyTap(), gauges: PerformanceGauges()),
            interval: .milliseconds(20), pipeline: pipeline)
    }

    @Test func theUserOrTheFlagShowsTheHUD() {
        let flags = FeatureFlags.inMemory()
        let hud = controller(flags: flags)
        #expect(!hud.isVisible)

        hud.setVisible(true)
        #expect(hud.isVisible)
        hud.toggleVisible()
        #expect(!hud.isVisible)

        flags.setOverride(true, for: .perfHUD)
        #expect(hud.isVisible, "The perfHUD flag shows it too")
        // Hiding it from Settings or the triple-tap wins over the flag.
        hud.setVisible(false)
        #expect(!hud.isVisible)
        #expect(flags.override(for: .perfHUD) == nil)
    }

    @Test func samplingReadsThePipelineAndStopsWithTheHUD() async throws {
        let tap = SignpostLatencyTap()
        var reads = 0
        let hud = PerformanceHUDController(
            flags: .inMemory(), preferences: .inMemory(),
            sampler: PerformanceHUDSampler(tap: tap, gauges: PerformanceGauges()),
            interval: .milliseconds(20)
        ) {
            reads += 1
            return PipelineReadings(turnState: "listening")
        }
        #expect(!hud.isRunning)

        let run = Task { await hud.run() }
        try await waitUntil { hud.sampleCount >= 3 }
        #expect(hud.isRunning)
        #expect(tap.isActive, "Signposts are timed while the HUD runs")
        #expect(reads >= 3)
        #expect(hud.readout.row("Turn")?.value == "listening")
        #expect(hud.readout.row("CPU")?.value != PerformanceHUDReadout.placeholder)
        #expect(hud.readout.row("Memory")?.value != PerformanceHUDReadout.placeholder)
        #expect(hud.readout.row("Thermal")?.value != PerformanceHUDReadout.placeholder)

        run.cancel()
        await run.value
        #expect(!hud.isRunning)
        #expect(!tap.isActive, "Nothing is timed once the HUD stops")
    }

    /// The display link wakes the main thread on every frame, the HUD's
    /// largest cost, so it only measures one interval in three.
    @Test func theDisplayLinkMeasuresOneIntervalInThree() {
        let hud = controller()
        hud.start()
        #expect(hud.isMeasuringFrameRate, "The first interval is measured")
        var measuring: [Bool] = []
        for _ in 0..<6 {
            hud.sample()
            measuring.append(hud.isMeasuringFrameRate)
        }
        #expect(measuring == [false, false, true, false, false, true])
        hud.stop()
        #expect(!hud.isMeasuringFrameRate)

        let always = PerformanceHUDController(
            flags: .inMemory(), preferences: .inMemory(),
            sampler: PerformanceHUDSampler(tap: SignpostLatencyTap(), gauges: PerformanceGauges()),
            frameRateDutyCycle: 1
        ) { PipelineReadings() }
        always.start()
        for _ in 0..<3 {
            always.sample()
            #expect(always.isMeasuringFrameRate)
        }
        always.stop()
    }

    /// #182: SwiftUI is told about a sample only when it changed what the
    /// panel shows. Observation reports every write, equal or not, and an
    /// update of the panel costs far more than the sample, so an idle app's
    /// compact HUD (whose rows rarely change) shouldn't be rendered again
    /// every second, nor for rows only the expanded panel shows.
    @Test func onlySamplesThatChangeTheCompactRowsUpdateThem() {
        var turnState = "listening"
        var firstAudio: LatencyStats?
        let hud = PerformanceHUDController(
            flags: .inMemory(), preferences: .inMemory(),
            sampler: PerformanceHUDSampler(
                memory: FixedMemory(), cpu: StillCPU(), thermal: { .nominal }, tap: SignpostLatencyTap(),
                gauges: PerformanceGauges())
        ) { PipelineReadings(turnState: turnState, firstAudio: firstAudio) }
        hud.start()
        defer { hud.stop() }

        // Counted in `onChange`, which runs in the property's `willSet`.
        let compactWrites = Mutex(0)
        func trackCompact() {
            withObservationTracking {
                _ = hud.compactRows
                _ = hud.level
            } onChange: {
                compactWrites.withLock { $0 += 1 }
            }
        }

        // Nothing changed: no writes at all.
        trackCompact()
        let updates = hud.compactUpdates
        for _ in 0..<3 { hud.sample() }
        #expect(compactWrites.withLock { $0 } == 0)
        #expect(hud.compactUpdates == updates)

        // An expanded-only row changed: the readout follows, the compact
        // panel isn't told.
        turnState = "thinking"
        hud.sample()
        #expect(hud.readout.row("Turn")?.value == "thinking")
        #expect(compactWrites.withLock { $0 } == 0)
        #expect(hud.compactUpdates == updates)

        // A compact row changed.
        firstAudio = LatencyStats(
            last: 640, p50: 640, p95: 640, mean: 640, maximum: 640, windowCount: 1, totalCount: 1)
        hud.sample()
        #expect(compactWrites.withLock { $0 } == 1)
        #expect(hud.compactUpdates == updates + 1)
        #expect(hud.compactRows.contains { $0.label == "EOU → audio" && $0.value != PerformanceHUDReadout.placeholder })
    }

    @Test func preferencesOutliveTheController() throws {
        let suite = "blau.tests.performanceHUD.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let first = controller(preferences: .userDefaults(suiteName: suite))
        first.setVisible(true)
        first.isExpanded = true
        first.position = CGPoint(x: 0.7, y: 1.4)

        let second = controller(preferences: .userDefaults(suiteName: suite))
        #expect(second.isVisible)
        #expect(second.isExpanded)
        #expect(second.position == CGPoint(x: 0.7, y: 1), "Positions are kept on screen")

        let fresh = controller(preferences: .inMemory())
        #expect(!fresh.isVisible)
        #expect(!fresh.isExpanded)
    }

    @Test func theVoiceLoopFillsItsRows() {
        let environment = AppEnvironment.preview()
        let readings = environment.voiceLoop.hudReadings()
        #expect(readings.turnState == "paused")
        #expect(readings.connection == "disconnected")
        #expect(readings.usage?.estimatedCostUSD == 0)
        // Fakes have no conversation audio and no running pipeline.
        #expect(readings.capture == nil)
        #expect(readings.voiceActivity == nil)
        #expect(readings.transcriber == nil)
    }

    @Test func theEnvironmentWiresTheHUDToItsFlags() {
        #expect(AppEnvironment.preview(flags: [.perfHUD: true]).performanceHUD.isVisible)
        #expect(!AppEnvironment.preview().performanceHUD.isVisible)
    }

    /// A process that uses no CPU time, so the CPU row stays the same.
    private struct StillCPU: CPUTimeSource {
        func processCPUTime() -> UInt64 { 0 }
        func threadCPUTime() -> UInt64 { 0 }
        func wallTime() -> UInt64 { 0 }
    }

    /// A footprint that never moves, so the memory row stays the same.
    private struct FixedMemory: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 100 * 1_048_576, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
