import BlauTelemetry
import QuartzCore

/// Feeds a `FrameRateMeter` from a `CADisplayLink` on the main run loop.
///
/// The callbacks run on the main thread, so a busy main thread delays or
/// skips them; that is what the HUD's FPS shows. The link asks for 60 Hz
/// (30 Hz minimum) rather than the display's maximum, so it never holds a
/// ProMotion display at 120 Hz just to measure it. Each callback's own CPU
/// time is added up for the HUD's overhead (`takeCallbackCPUTime()`).
///
/// Every callback wakes the main run loop, which is most of the HUD's cost
/// (about 0.1 ms per wake-up in the Simulator, ~0.8% of a core at 60 Hz), so
/// the controller only measures part of the time: `pause()` keeps the last
/// full window's reading on screen while the link sleeps, and `resume()`
/// starts a fresh window.
@MainActor
final class FrameRateMonitor {
    private var meter = FrameRateMeter()
    private var link: CADisplayLink?
    private var callbackCPUTime: UInt64 = 0
    private var heldReading: FrameRateReading?
    private let clock = SystemCPUTimeSource()

    /// The frame rate over the last second measured, or `nil` until two
    /// frames.
    var reading: FrameRateReading? {
        isMeasuring ? meter.reading ?? heldReading : heldReading
    }

    /// Whether the display link exists (between `start()` and `stop()`).
    var isRunning: Bool { link != nil }

    /// Whether the display link is delivering frames (running, not paused).
    var isMeasuring: Bool { link.map { !$0.isPaused } ?? false }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(
            target: DisplayLinkTarget(monitor: self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        meter.reset()
        heldReading = nil
        callbackCPUTime = 0
    }

    /// Stops the callbacks, keeping the latest reading.
    func pause() {
        guard let link, !link.isPaused else { return }
        heldReading = meter.reading ?? heldReading
        link.isPaused = true
    }

    /// Restarts the callbacks with a fresh window, so the pause isn't
    /// counted as dropped frames.
    func resume() {
        guard let link, link.isPaused else { return }
        meter.reset()
        link.isPaused = false
    }

    /// The CPU time spent in display-link callbacks since the last call.
    func takeCallbackCPUTime() -> UInt64 {
        defer { callbackCPUTime = 0 }
        return callbackCPUTime
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let start = clock.threadCPUTime()
        meter.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        callbackCPUTime += clock.threadCPUTime() &- start
    }
}

/// The display link's target. `CADisplayLink` retains its target, so this
/// holds the monitor weakly and the link never keeps it alive.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var monitor: FrameRateMonitor?

    init(monitor: FrameRateMonitor) {
        self.monitor = monitor
    }

    @objc func tick(_ link: CADisplayLink) {
        monitor?.tick(link)
    }
}
