import Foundation
import Synchronization
import Testing

@testable import BlauTelemetry

@Suite("CPU usage and overhead")
struct CPUUsageTests {
    @Test func cpuPercentIsCPUTimeOverWallTime() {
        var meter = CPUUsageMeter()
        #expect(meter.sample(cpu: 0, wall: 0) == nil, "The first reading only sets the baseline")
        // 250 ms of CPU in 500 ms of wall time: half a core.
        #expect(meter.sample(cpu: 250_000_000, wall: 500_000_000) == 50)
        // Two busy cores read 200%, like Xcode's gauge.
        #expect(meter.sample(cpu: 1_250_000_000, wall: 1_000_000_000) == 200)
        // No wall time passed: no reading.
        #expect(meter.sample(cpu: 1_300_000_000, wall: 1_000_000_000) == nil)
        meter.reset()
        #expect(meter.sample(cpu: 5, wall: 5) == nil)
    }

    @Test func theSystemClocksMeasureABusyThread() {
        let source = SystemCPUTimeSource()
        var meter = CPUUsageMeter()
        let processStart = source.processCPUTime()
        let wallStart = source.wallTime()
        _ = meter.sample(cpu: processStart, wall: wallStart)
        let threadStart = source.threadCPUTime()
        // Spin until the thread clock says this thread used 100 ms of CPU.
        // How long that takes in wall time depends on how loaded the host
        // is, so the checks below compare the clocks with each other rather
        // than with the wall clock (a CI host with a load average far above
        // its core count preempts the thread most of the time).
        let target: UInt64 = 100_000_000
        let deadline = ContinuousClock.now + .seconds(30)
        var spins = 0
        while source.threadCPUTime() - threadStart < target, ContinuousClock.now < deadline { spins &+= 1 }
        let threadCPU = source.threadCPUTime() - threadStart
        let processCPU = source.processCPUTime() - processStart
        let wall = source.wallTime() - wallStart
        let percent = meter.sample(cpu: source.processCPUTime(), wall: source.wallTime())
        #expect(spins > 0)
        #expect(threadCPU >= target)
        // The process clock counts this thread's time, and no single thread
        // runs for longer than the wall time that passed.
        #expect(processCPU >= threadCPU)
        #expect(threadCPU <= wall + 1_000_000)
        // The meter reports the process's share of a core over that span.
        let expected = Double(processCPU) / Double(wall) * 100
        #expect(abs((percent ?? 0) - expected) <= max(5, expected * 0.1))
        #expect((percent ?? 0) > 0)
    }

    @Test func overheadIsChargedTimeOverTheWindow() {
        var meter = OverheadMeter(windowSeconds: 10)
        meter.start(at: 1_000_000_000)
        #expect(meter.fraction(now: 1_000_000_000) == nil)
        meter.charge(nanoseconds: 1_000_000, at: 1_500_000_000)
        // 1 ms over 1 s: 0.1%.
        #expect(meter.fraction(now: 2_000_000_000) == 0.001)
        meter.charge(nanoseconds: 9_000_000, at: 3_000_000_000)
        // 10 ms over 10 s.
        #expect(meter.fraction(now: 11_000_000_000) == 0.001)
        // The first charge slid out of the window.
        let later = meter.fraction(now: 12_000_000_000)
        #expect(abs((later ?? 0) - 0.0009) < 1e-12)
    }
}

@Suite("FrameRateMeter")
struct FrameRateMeterTests {
    @Test func aSteadyDisplayLinkReadsItsRefreshRate() throws {
        var meter = FrameRateMeter()
        #expect(meter.reading == nil)
        let interval = 1.0 / 60
        for frame in 0...120 {
            let time = 10 + Double(frame) * interval
            meter.record(timestamp: time, targetTimestamp: time + interval)
        }
        let reading = try #require(meter.reading)
        #expect(abs(reading.framesPerSecond - 60) < 0.5)
        #expect(abs((reading.targetFramesPerSecond ?? 0) - 60) < 0.01)
        #expect(reading.droppedFrames == 0)
        #expect(abs(reading.longestFrame - interval) < 1e-6)
    }

    @Test func aStalledMainThreadDropsFrames() throws {
        var meter = FrameRateMeter()
        let interval = 1.0 / 60
        var time = 100.0
        for _ in 0..<30 {
            meter.record(timestamp: time, targetTimestamp: time + interval)
            time += interval
        }
        // A 100 ms hitch: the callbacks for five refreshes never ran.
        time += 5 * interval
        meter.record(timestamp: time, targetTimestamp: time + interval)
        let reading = try #require(meter.reading)
        #expect(reading.droppedFrames == 5)
        #expect(abs(reading.longestFrame - 6 * interval) < 1e-9)
        #expect(reading.framesPerSecond < 60)

        // A second later the hitch has left the window.
        for _ in 0..<70 {
            time += interval
            meter.record(timestamp: time, targetTimestamp: time + interval)
        }
        #expect(meter.reading?.droppedFrames == 0)
    }

    @Test func jitterIsNotADrop() throws {
        var meter = FrameRateMeter()
        let interval = 1.0 / 120
        var time = 0.0
        for frame in 0..<60 {
            time += interval * (frame.isMultiple(of: 2) ? 1.3 : 0.7)
            meter.record(timestamp: time, targetTimestamp: time + interval)
        }
        #expect(try #require(meter.reading).droppedFrames == 0)
        meter.reset()
        #expect(meter.reading == nil)
    }
}

@Suite("PerformanceGauges")
struct PerformanceGaugesTests {
    @Test func keepsTheLatestValueOfEachGauge() throws {
        let gauges = PerformanceGauges()
        #expect(gauges.reading(.voiceScore) == nil)
        gauges.report(.voiceScore, 0.61)
        gauges.report(.voiceScore, 0.72)
        gauges.report(.topicDepth, .nan)
        let score = try #require(gauges.reading(.voiceScore))
        #expect(score.value == 0.72)
        #expect(score.count == 2)
        #expect(gauges.reading(.topicDepth) == nil)
        gauges.clear(.voiceScore)
        #expect(gauges.reading(.voiceScore) == nil)
    }

    @Test func thermalStatesMapFromProcessInfo() {
        #expect(DeviceThermalState(.nominal) == .nominal)
        #expect(DeviceThermalState(.fair) == .fair)
        #expect(DeviceThermalState(.serious) == .serious)
        #expect(DeviceThermalState(.critical) == .critical)
        #expect(DeviceThermalState.critical.isThrottling)
        #expect(!DeviceThermalState.fair.isThrottling)
        #expect(DeviceThermalState.allCases.contains(.current))
    }
}
