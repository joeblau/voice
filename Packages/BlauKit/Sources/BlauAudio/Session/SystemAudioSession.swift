#if os(iOS)
    import AVFAudio
    import BlauCore
    import Foundation
    import Synchronization

    /// The production `AudioSessionBackend`: `AVAudioSession.sharedInstance()`
    /// and its notifications.
    ///
    /// Interruptions are read from `AVAudioSession.interruptionNotification`,
    /// which iOS 27 deprecates but still posts, because the deployment target
    /// is iOS 26. On iOS 27 the replacement notifications
    /// (`didBecomeInactiveNotification` and
    /// `resumptionRecommendationNotification`) are observed as well. Both
    /// describe the same interruption; the controller's state machine ignores
    /// the duplicate (a second "began" while interrupted, or a second "ended"
    /// once resumed, changes nothing).
    public final class SystemAudioSession: AudioSessionBackend {
        public let events: AsyncStream<AudioSessionEvent>

        private let continuation: AsyncStream<AudioSessionEvent>.Continuation
        private let observers: Mutex<[any NSObjectProtocol]>
        private let center: NotificationCenter

        /// - Parameter center: Where to observe session notifications. Tests
        ///   pass their own center and post simulated notifications to it.
        public init(center: NotificationCenter = .default) {
            self.center = center
            let (events, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
            self.events = events
            self.continuation = continuation

            let session = AVAudioSession.sharedInstance()
            var tokens: [any NSObjectProtocol] = []

            tokens.append(
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) {
                    note in
                    if let event = Self.interruptionEvent(userInfo: note.userInfo) {
                        continuation.yield(event)
                    }
                }
            )
            tokens.append(
                center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) {
                    note in
                    // Read the route when the notification arrives, not later.
                    let route = Self.route(AVAudioSession.sharedInstance().currentRoute)
                    continuation.yield(.routeChanged(Self.routeChangeReason(userInfo: note.userInfo), route: route))
                }
            )
            tokens.append(
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereLostNotification,
                    object: session,
                    queue: nil
                ) { _ in
                    continuation.yield(.mediaServicesLost)
                }
            )
            tokens.append(
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification,
                    object: session,
                    queue: nil
                ) { _ in
                    continuation.yield(.mediaServicesReset)
                }
            )
            if #available(iOS 27, *) {
                tokens += Self.observeActivationNotifications(
                    center: center, session: session, continuation: continuation)
            }

            observers = Mutex(tokens)
        }

        deinit {
            let tokens = observers.withLock { tokens in
                let all = tokens
                tokens.removeAll()
                return all
            }
            for token in tokens {
                center.removeObserver(token)
            }
            continuation.finish()
        }

        // MARK: AudioSessionBackend

        public func configure(_ configuration: AudioSessionConfiguration) throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: Self.options(for: configuration))
            try session.setPreferredSampleRate(configuration.preferredSampleRate)
            try session.setPreferredIOBufferDuration(configuration.preferredIOBufferDuration.timeInterval)
        }

        public func isConfigured(for configuration: AudioSessionConfiguration) -> Bool {
            let session = AVAudioSession.sharedInstance()
            return session.category == .playAndRecord
                && session.mode == .voiceChat
                && session.categoryOptions.isSuperset(of: Self.options(for: configuration))
        }

        public func activate() throws {
            try AVAudioSession.sharedInstance().setActive(true)
        }

        public func deactivate() throws {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        public var currentRoute: AudioRoute {
            Self.route(AVAudioSession.sharedInstance().currentRoute)
        }

        // MARK: Translation

        static func options(for configuration: AudioSessionConfiguration) -> AVAudioSession.CategoryOptions {
            var options: AVAudioSession.CategoryOptions = []
            if configuration.routesToSpeakerByDefault {
                options.insert(.defaultToSpeaker)
            }
            if configuration.allowsBluetoothHFP {
                options.insert(.allowBluetoothHFP)
            }
            return options
        }

        static func interruptionEvent(userInfo: [AnyHashable: Any]?) -> AudioSessionEvent? {
            guard
                let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return nil }

            switch type {
            case .began:
                let rawReason = userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let reason = rawReason.flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
                return .interruptionBegan(interruptionReason(reason))
            case .ended:
                let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                return .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        }

        static func interruptionReason(_ reason: AVAudioSession.InterruptionReason?) -> AudioInterruptionReason {
            // The key is optional; without it, another session took over.
            guard let reason else { return .default }
            switch reason {
            case .default: return .default
            case .builtInMicMuted: return .builtInMicMuted
            case .routeDisconnected: return .routeDisconnected
            default: return .unknown
            }
        }

        static func routeChangeReason(userInfo: [AnyHashable: Any]?) -> AudioRouteChangeReason {
            guard
                let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return .unknown }

            switch reason {
            case .newDeviceAvailable: return .newDeviceAvailable
            case .oldDeviceUnavailable: return .oldDeviceUnavailable
            case .categoryChange: return .categoryChange
            case .override: return .override
            case .wakeFromSleep: return .wakeFromSleep
            case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
            case .routeConfigurationChange: return .routeConfigurationChange
            case .unknown: return .unknown
            @unknown default: return .unknown
            }
        }

        static func route(_ description: AVAudioSessionRouteDescription) -> AudioRoute {
            AudioRoute(inputs: description.inputs.map(port), outputs: description.outputs.map(port))
        }

        static func port(_ description: AVAudioSessionPortDescription) -> AudioPort {
            AudioPort(kind: portKind(description.portType), name: description.portName, uid: description.uid)
        }

        static func portKind(_ port: AVAudioSession.Port) -> AudioPortKind {
            switch port {
            case .builtInMic: .builtInMic
            case .builtInSpeaker: .builtInSpeaker
            case .builtInReceiver: .builtInReceiver
            case .headsetMic: .headsetMic
            case .headphones: .headphones
            case .bluetoothHFP: .bluetoothHFP
            case .bluetoothA2DP: .bluetoothA2DP
            case .bluetoothLE: .bluetoothLE
            case .airPlay: .airPlay
            case .carAudio: .carAudio
            case .usbAudio: .usbAudio
            case .HDMI: .hdmi
            case .lineIn: .lineIn
            case .lineOut: .lineOut
            case .continuityMicrophone: .continuityMicrophone
            default: .other
            }
        }

        // MARK: iOS 27 activation notifications

        @available(iOS 27, *)
        private static func observeActivationNotifications(
            center: NotificationCenter,
            session: AVAudioSession,
            continuation: AsyncStream<AudioSessionEvent>.Continuation
        ) -> [any NSObjectProtocol] {
            let inactive = center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification,
                object: session,
                queue: nil
            ) { note in
                let context =
                    note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                // Our own deactivation (source .app) is not an interruption.
                guard let context, context.source == .system else { return }
                continuation.yield(.interruptionBegan(interruptionReason(context.interruptionContext?.reason)))
            }
            let resumption = center.addObserver(
                forName: AVAudioSession.resumptionRecommendationNotification,
                object: session,
                queue: nil
            ) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                continuation.yield(.interruptionEnded(shouldResume: context?.recommendation == .shouldResume))
            }
            return [inactive, resumption]
        }
    }

    extension AudioSessionController {
        /// The production controller: the shared `AVAudioSession`, a
        /// voice-processing `AVAudioEngine` and `AVAudioApplication` permission.
        public static func live(configuration: AudioSessionConfiguration = .voiceChat) -> AudioSessionController {
            AudioSessionController(
                session: SystemAudioSession(),
                permission: SystemMicrophonePermission(),
                configuration: configuration,
                makeEngine: { VoiceProcessingAudioEngine() }
            )
        }
    }
#endif
