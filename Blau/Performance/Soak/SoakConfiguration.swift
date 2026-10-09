#if DEBUG || BLAU_PERF
    import BlauRealtime
    import Foundation

    /// How the long-session soak test (#76) runs. Read from the launch
    /// environment `SoakTests` (and `make soak`) sets; see docs/soak.md.
    struct SoakConfiguration: Sendable, Hashable {
        /// Spoken length of the session, on the audio timeline.
        var duration: Duration = .seconds(120 * 60)
        /// How many times faster than real time the audio plays, or `nil`
        /// for as fast as the pipeline takes it.
        var speed: Double? = 10
        var recognizer: PerfReplayConfiguration.Recognizer = .scripted
        /// Where on the audio timeline the realtime session should be
        /// renewed: xAI's 110 minutes are scaled so the renewal lands
        /// there. `nil` keeps xAI's real schedule (only scaled by `speed`).
        var rolloverAt: Duration? = .seconds(72 * 60)
        /// Audio between two samples.
        var sampleInterval: Duration = .seconds(60)

        /// Launch environment variable that opens the soak screen.
        static let enabledKey = "BLAU_SOAK"
        static let minutesKey = "BLAU_SOAK_MINUTES"
        static let speedKey = "BLAU_SOAK_SPEED"
        static let recognizerKey = "BLAU_SOAK_ASR"
        static let rolloverKey = "BLAU_SOAK_ROLLOVER_MINUTES"
        static let sampleKey = "BLAU_SOAK_SAMPLE_SECONDS"

        /// The speed the session clock is scaled by when the audio plays as
        /// fast as it can: about what the pipeline manages on a Mac.
        static let assumedMaximumSpeed = 10.0

        static func isRequested(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            environment[enabledKey] == "1"
        }

        /// The configuration in `environment`:
        ///
        /// - `BLAU_SOAK_MINUTES`: the session's length (default 120).
        /// - `BLAU_SOAK_SPEED`: a factor, `realtime` or `max` (default 10).
        /// - `BLAU_SOAK_ASR`: `scripted` (default) or `parakeet`.
        /// - `BLAU_SOAK_ROLLOVER_MINUTES`: where on the audio timeline the
        ///   session renewal should land (default 60% of the session), or
        ///   `xai` for xAI's real 110 minutes.
        /// - `BLAU_SOAK_SAMPLE_SECONDS`: audio between samples (default a
        ///   120th of the session, at least 10 s).
        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            if let minutes = environment[Self.minutesKey].flatMap(Double.init), minutes > 0 {
                duration = .seconds(minutes * 60)
            }
            switch environment[Self.speedKey] {
            case "max": speed = nil
            case "realtime": speed = 1
            case let value?: speed = Double(value).flatMap { $0 > 0 ? $0 : nil } ?? speed
            case nil: break
            }
            if let recognizer = environment[Self.recognizerKey].flatMap(PerfReplayConfiguration.Recognizer.init) {
                self.recognizer = recognizer
            }
            switch environment[Self.rolloverKey] {
            case "xai":
                rolloverAt = nil
            case let value?:
                rolloverAt =
                    Double(value).flatMap { $0 > 0 ? .seconds($0 * 60) : nil } ?? Self.defaultRollover(duration)
            case nil:
                rolloverAt = Self.defaultRollover(duration)
            }
            sampleInterval = Self.defaultSampleInterval(duration)
            if let seconds = environment[Self.sampleKey].flatMap(Double.init), seconds > 0 {
                sampleInterval = .seconds(seconds)
            }
        }

        init(
            duration: Duration, speed: Double?, recognizer: PerfReplayConfiguration.Recognizer = .scripted,
            rolloverAt: Duration? = nil, sampleInterval: Duration? = nil
        ) {
            self.duration = duration
            self.speed = speed
            self.recognizer = recognizer
            self.rolloverAt = rolloverAt ?? Self.defaultRollover(duration)
            self.sampleInterval = sampleInterval ?? Self.defaultSampleInterval(duration)
        }

        /// 60% of the way through: late enough that the session has run
        /// long, early enough that the conversation goes on for a good while
        /// after the renewal.
        static func defaultRollover(_ duration: Duration) -> Duration { duration * 0.6 }

        static func defaultSampleInterval(_ duration: Duration) -> Duration { max(.seconds(10), duration / 120) }

        /// How much faster than xAI's the session clock runs: the realtime
        /// session's age limits are divided by it.
        var sessionTimeScale: Double {
            let speed = speed ?? Self.assumedMaximumSpeed
            guard let rolloverAt, rolloverAt > .zero else { return speed }
            let standard = SessionContinuityConfiguration.standard.rolloverAfter ?? .seconds(110 * 60)
            return speed * (standard / rolloverAt)
        }

        /// The orchestrator's session continuity for this run: xAI's
        /// schedule, scaled.
        var continuity: SessionContinuityConfiguration {
            SessionContinuityConfiguration.standard.scaled(by: sessionTimeScale)
        }

        /// The fewest renewals a run lasting `wallTime` (from the first
        /// connection) must have made: every session ends by its deadline.
        func expectedRollovers(wallTime: Duration) -> Int {
            let deadline = continuity.rolloverDeadline
            guard deadline > .zero, continuity.rolloverAfter != nil else { return 0 }
            // A renewal itself takes a moment (one WebSocket upgrade); allow
            // a second per renewal.
            let available = wallTime - .seconds(1)
            guard available > .zero else { return 0 }
            return Int((available / (deadline + .seconds(1))).rounded(.down))
        }

        var summary: String {
            let speed = speed.map { "\($0.formatted())x" } ?? "max speed"
            let rollover = rolloverAt.map { "renewal at \(Int($0 / .seconds(60))) min" } ?? "xAI renewal schedule"
            return "\(Int(duration / .seconds(60))) min session at \(speed), \(recognizer.rawValue) ASR, \(rollover)"
        }
    }
#endif
