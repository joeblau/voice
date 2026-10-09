import BlauTelemetry
import Foundation

#if os(iOS)
    import AVFAudio
#endif

extension AudioHardwareLatency {
    /// The hardware latency from `AVAudioSession`'s readings, in seconds,
    /// and the route they apply to (port kinds only, no device names).
    public init(
        inputLatency: TimeInterval, outputLatency: TimeInterval, ioBufferDuration: TimeInterval, sampleRate: Double,
        route: AudioRoute
    ) {
        self.init(
            inputMilliseconds: Self.milliseconds(inputLatency),
            outputMilliseconds: Self.milliseconds(outputLatency),
            ioBufferMilliseconds: Self.milliseconds(ioBufferDuration),
            sampleRate: sampleRate.isFinite && sampleRate > 0 ? sampleRate : 0,
            route: route.summary)
    }

    /// Seconds as milliseconds; zero for a reading the session couldn't
    /// make (negative or not a number before the session is active).
    private static func milliseconds(_ seconds: TimeInterval) -> Double {
        seconds.isFinite && seconds > 0 ? seconds * 1_000 : 0
    }
}

#if os(iOS)
    extension SystemAudioSession {
        /// The current route's hardware latency (#74): how long the
        /// microphone takes to reach the capture timestamps and a rendered
        /// frame to reach the speaker. The latency budget adds it to each
        /// turn's total; the values change with the route (AirPods add
        /// much more than the built-in speaker).
        public static func hardwareLatency() -> AudioHardwareLatency {
            let session = AVAudioSession.sharedInstance()
            return AudioHardwareLatency(
                inputLatency: session.inputLatency, outputLatency: session.outputLatency,
                ioBufferDuration: session.ioBufferDuration, sampleRate: session.sampleRate,
                route: route(session.currentRoute))
        }
    }
#endif
