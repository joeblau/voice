import BlauCore
import BlauTelemetry
import Foundation
import Observation
import Synchronization

/// The debug performance HUD's state (#71): whether it shows, compact or
/// expanded, where it sits, and the readout it shows, refreshed once a
/// second while it is on screen.
///
/// The HUD shows when the user turned it on (Settings → Developer, or a
/// triple-tap on the main screen in DEBUG builds) or when the `perfHUD`
/// feature flag is on (the debug menu, or `-blau.featureFlag.perfHUD YES`
/// for one launch). The user's choice, the expanded state and the position
/// are kept in `PerformanceHUDPreferences`; release builds honour them too,
/// so a TestFlight build can show the HUD.
///
/// Nothing is measured while the HUD is hidden: `run()` (driven by the
/// overlay's `.task` while the app is active) starts the display link and
/// the signpost tap, and stops both when it is cancelled.
@MainActor
@Observable
final class PerformanceHUDController {
    /// Whether the user turned the HUD on.
    private(set) var isEnabledByUser: Bool
    /// Whether the HUD shows every section rather than the compact rows.
    var isExpanded: Bool {
        didSet { preferences.setExpanded(isExpanded) }
    }
    /// The HUD's centre as a fraction of the space it can move in.
    var position: CGPoint {
        didSet { preferences.setPosition(position) }
    }
    /// What the HUD shows now.
    private(set) var readout = PerformanceHUDReadout(PerformanceHUDSnapshot())
    /// Samples taken since the HUD appeared.
    private(set) var sampleCount = 0

    @ObservationIgnored let flags: FeatureFlags
    @ObservationIgnored private let preferences: PerformanceHUDPreferences
    @ObservationIgnored private let pipeline: @MainActor () -> PipelineReadings
    @ObservationIgnored private var sampler: PerformanceHUDSampler
    @ObservationIgnored private let frameRate = FrameRateMonitor()
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let frameRateDutyCycle: Int

    /// - Parameters:
    ///   - flags: The `perfHUD` flag also shows the HUD.
    ///   - preferences: Where the user's choices are kept.
    ///   - sampler: Reads the device, the signposts and the gauges.
    ///   - interval: How often the readout refreshes.
    ///   - frameRateDutyCycle: The display link measures one `interval` in
    ///     every this many, and sleeps the rest. Each display-link callback
    ///     wakes the main thread, the HUD's largest cost; 3 keeps the whole
    ///     HUD well under 1% of a core while the FPS row still refreshes
    ///     every few seconds. Pass 1 to measure all the time.
    ///   - pipeline: Reads the voice pipeline (the voice loop).
    init(
        flags: FeatureFlags,
        preferences: PerformanceHUDPreferences,
        sampler: PerformanceHUDSampler = PerformanceHUDSampler(),
        interval: Duration = PerformanceHUDSampler.defaultInterval,
        frameRateDutyCycle: Int = 3,
        pipeline: @escaping @MainActor () -> PipelineReadings
    ) {
        precondition(frameRateDutyCycle >= 1, "The display link must measure at least one interval in every cycle")
        self.flags = flags
        self.preferences = preferences
        self.sampler = sampler
        self.interval = interval
        self.frameRateDutyCycle = frameRateDutyCycle
        self.pipeline = pipeline
        isEnabledByUser = preferences.isEnabled
        isExpanded = preferences.isExpanded
        position = preferences.position
    }

    /// Whether the HUD is on screen.
    var isVisible: Bool {
        isEnabledByUser || flags.isEnabled(.perfHUD)
    }

    /// Shows or hides the HUD. Hiding it also clears a `perfHUD` flag
    /// override, so the switch the user flipped is the one that wins.
    func setVisible(_ visible: Bool) {
        isEnabledByUser = visible
        preferences.setEnabled(visible)
        if !visible, flags.override(for: .perfHUD) == true {
            flags.setOverride(nil, for: .perfHUD)
        }
        Log.ui.notice("Performance HUD \(visible ? "shown" : "hidden", privacy: .public)")
    }

    /// Shows the HUD if it is hidden and hides it if it shows.
    func toggleVisible() {
        setVisible(!isVisible)
    }

    /// Whether `run()` is measuring.
    var isRunning: Bool { sampler.isRunning }

    /// Measures and refreshes the readout until the calling task is
    /// cancelled, then stops measuring.
    func run() async {
        start()
        defer { stop() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
            sample()
        }
    }

    /// Starts measuring: the display link and the signpost tap.
    func start() {
        guard !sampler.isRunning else { return }
        sampler.start()
        frameRate.start()
        sampleCount = 0
        sample()
    }

    /// Stops measuring.
    func stop() {
        guard sampler.isRunning else { return }
        frameRate.stop()
        sampler.stop()
    }

    /// Whether the display link is measuring right now (it sleeps part of
    /// the time, see `frameRateDutyCycle`).
    var isMeasuringFrameRate: Bool { frameRate.isMeasuring }

    /// Takes one reading and refreshes the readout, then wakes or pauses the
    /// display link for the next interval.
    func sample() {
        sampler.chargeExternal(nanoseconds: frameRate.takeCallbackCPUTime())
        let pipeline = pipeline
        readout = sampler.sample(frameRate: frameRate.reading) { pipeline() }
        sampleCount += 1
        // The interval after the first sample (taken at start) is measured,
        // then one in every `frameRateDutyCycle`.
        if (sampleCount - 1) % frameRateDutyCycle == 0 {
            frameRate.resume()
        } else {
            frameRate.pause()
        }
    }
}

// MARK: - Preferences

/// The HUD settings that outlive a launch. The live app keeps them in
/// `UserDefaults`; previews and tests keep them in memory.
final class PerformanceHUDPreferences: Sendable {
    private struct Values: Sendable {
        var isEnabled = false
        var isExpanded = false
        /// Near the top-left corner, clear of the navigation bar.
        var position = CGPoint(x: 0.3, y: 0.18)
    }

    private enum Key {
        static let enabled = "blau.performanceHUD.enabled"
        static let expanded = "blau.performanceHUD.expanded"
        static let positionX = "blau.performanceHUD.positionX"
        static let positionY = "blau.performanceHUD.positionY"
    }

    /// `UserDefaults` isn't `Sendable`, but it is documented thread-safe;
    /// the suite name is all that's kept.
    private let suiteName: String?
    private let isPersistent: Bool
    private let memory: Mutex<Values>

    private init(suiteName: String?, isPersistent: Bool) {
        self.suiteName = suiteName
        self.isPersistent = isPersistent
        var values = Values()
        if isPersistent {
            let defaults = Self.defaults(suiteName)
            values.isEnabled = defaults.bool(forKey: Key.enabled)
            values.isExpanded = defaults.bool(forKey: Key.expanded)
            if defaults.object(forKey: Key.positionX) != nil {
                values.position = CGPoint(
                    x: defaults.double(forKey: Key.positionX), y: defaults.double(forKey: Key.positionY))
            }
        }
        memory = Mutex(values)
    }

    /// Kept in `UserDefaults.standard`, or the suite `suiteName`.
    static func userDefaults(suiteName: String? = nil) -> PerformanceHUDPreferences {
        PerformanceHUDPreferences(suiteName: suiteName, isPersistent: true)
    }

    /// Kept in memory only, starting from the defaults.
    static func inMemory() -> PerformanceHUDPreferences {
        PerformanceHUDPreferences(suiteName: nil, isPersistent: false)
    }

    var isEnabled: Bool { memory.withLock { $0.isEnabled } }
    var isExpanded: Bool { memory.withLock { $0.isExpanded } }
    var position: CGPoint { memory.withLock { $0.position } }

    func setEnabled(_ value: Bool) {
        memory.withLock { $0.isEnabled = value }
        persist { $0.set(value, forKey: Key.enabled) }
    }

    func setExpanded(_ value: Bool) {
        memory.withLock { $0.isExpanded = value }
        persist { $0.set(value, forKey: Key.expanded) }
    }

    func setPosition(_ value: CGPoint) {
        let clamped = CGPoint(x: min(max(value.x, 0), 1), y: min(max(value.y, 0), 1))
        memory.withLock { $0.position = clamped }
        persist {
            $0.set(Double(clamped.x), forKey: Key.positionX)
            $0.set(Double(clamped.y), forKey: Key.positionY)
        }
    }

    private func persist(_ write: (UserDefaults) -> Void) {
        guard isPersistent else { return }
        write(Self.defaults(suiteName))
    }

    private static func defaults(_ suiteName: String?) -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
