/// Produces the performance HUD's snapshots and readouts, once a second
/// while the HUD is showing.
///
/// ```swift
/// var sampler = PerformanceHUDSampler()
/// sampler.start()                       // the HUD appeared
/// let readout = sampler.sample(frameRate: meter.reading) { pipelineReadings() }
/// sampler.stop()                        // the HUD went away
/// ```
///
/// The sampler keeps the HUD's cost visible and bounded:
///
/// - `start()` activates `SignpostLatencyTap` and `stop()` deactivates it,
///   so nothing is timed while the HUD is hidden.
/// - Each `sample` measures the CPU time of its own thread around the whole
///   call (reading every probe, the pipeline closure and building the
///   readout) and charges it, plus whatever the caller reports with
///   `chargeExternal(nanoseconds:)` (the display-link callbacks), to an
///   `OverheadMeter`. `overhead` in the snapshot and the "HUD cost" row show
///   the result as a share of one core.
public struct PerformanceHUDSampler: Sendable {
    /// The default sampling period. One reading a second matches the frame
    /// rate's one-second window, is as often as anyone can read the values,
    /// and keeps the SwiftUI updates of the panel, the HUD's largest cost,
    /// well under the 1% budget.
    /// the values and keeps the HUD's own cost far below 1% of a core.
    public static let defaultInterval: Duration = .seconds(1)

    private let memory: any MemoryProbe
    private let cpu: any CPUTimeSource
    private let thermal: @Sendable () -> DeviceThermalState
    private let tap: SignpostLatencyTap
    private let gauges: PerformanceGauges

    private var cpuMeter = CPUUsageMeter()
    private var overheadMeter: OverheadMeter
    private var pendingExternal: UInt64 = 0

    /// The latest snapshot.
    public private(set) var snapshot = PerformanceHUDSnapshot()
    /// Whether `start()` was called without a matching `stop()`.
    public private(set) var isRunning = false

    public init(
        memory: any MemoryProbe = ProcessMemoryProbe(),
        cpu: any CPUTimeSource = SystemCPUTimeSource(),
        thermal: @escaping @Sendable () -> DeviceThermalState = { .current },
        tap: SignpostLatencyTap = .shared,
        gauges: PerformanceGauges = .shared,
        overheadWindowSeconds: Double = 10
    ) {
        self.memory = memory
        self.cpu = cpu
        self.thermal = thermal
        self.tap = tap
        self.gauges = gauges
        overheadMeter = OverheadMeter(windowSeconds: overheadWindowSeconds)
    }

    /// The HUD appeared: starts timing signposts and measuring overhead.
    public mutating func start() {
        guard !isRunning else { return }
        isRunning = true
        tap.activate()
        cpuMeter.reset()
        _ = cpuMeter.sample(cpu: cpu.processCPUTime(), wall: cpu.wallTime())
        overheadMeter.start(at: cpu.wallTime())
        pendingExternal = 0
    }

    /// The HUD went away: stops timing signposts.
    public mutating func stop() {
        guard isRunning else { return }
        isRunning = false
        tap.deactivate()
    }

    /// Charges CPU time the HUD spent outside `sample`, such as the display
    /// link's callbacks since the previous sample.
    public mutating func chargeExternal(nanoseconds: UInt64) {
        pendingExternal += nanoseconds
    }

    /// Takes a reading of everything and returns the HUD's text for it.
    ///
    /// - Parameters:
    ///   - frameRate: The display link's frame rate, if it is running.
    ///   - pipeline: Reads the voice pipeline. Runs inside the measured
    ///     span, so its cost counts as HUD overhead.
    @discardableResult
    public mutating func sample(
        frameRate: FrameRateReading?,
        pipeline: () -> PipelineReadings
    ) -> PerformanceHUDReadout {
        let threadStart = cpu.threadCPUTime()
        let wall = cpu.wallTime()

        var snapshot = PerformanceHUDSnapshot(
            frameRate: frameRate,
            cpuPercent: cpuMeter.sample(cpu: cpu.processCPUTime(), wall: wall),
            memory: memory.snapshot(),
            thermalState: thermal(),
            pipeline: pipeline(),
            intervals: tap.allStats(),
            voiceScore: gauges.reading(.voiceScore),
            voiceThreshold: gauges.reading(.voiceThreshold),
            topicDepth: gauges.reading(.topicDepth),
            topicThreshold: gauges.reading(.topicThreshold)
        )
        snapshot.overhead = overheadMeter.fraction(now: wall)
        let readout = PerformanceHUDReadout(snapshot)
        self.snapshot = snapshot

        let threadEnd = cpu.threadCPUTime()
        let spent = (threadEnd >= threadStart ? threadEnd - threadStart : 0) + pendingExternal
        pendingExternal = 0
        overheadMeter.charge(nanoseconds: spent, at: wall)
        return readout
    }
}
