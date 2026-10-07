import AVFAudio
import Foundation

/// The production `AudioEngineBackend`: an `AVAudioEngine` whose I/O unit
/// runs Apple's voice processing (echo cancellation, noise suppression and
/// automatic gain control).
///
/// Voice processing can only be switched while the engine is stopped, so
/// `prepare` enables it before any component is installed and before
/// `start()`. Enabling it on the input node enables it on the output node
/// too, so playback through the speaker is cancelled out of the mic signal.
public final class VoiceProcessingAudioEngine: AudioEngineBackend {
    /// The engine. Graph components get it in `install(on:)`; other code
    /// should not touch it.
    public let engine: AVAudioEngine

    public let configurationChanges: AsyncStream<Void>

    private let changesContinuation: AsyncStream<Void>.Continuation
    private var configurationObserver: (any NSObjectProtocol)?
    private var installed: [any AudioGraphComponent] = []

    public init() {
        let engine = AVAudioEngine()
        self.engine = engine
        // Only "something changed" matters, so keep at most one pending.
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        configurationChanges = changes
        changesContinuation = continuation
        // Posted on an internal queue after the engine has stopped itself.
        // Only signal here: tearing the engine down from this callback can
        // deadlock (see AVAudioEngineConfigurationChangeNotification).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            continuation.yield()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        changesContinuation.finish()
    }

    public var isRunning: Bool { engine.isRunning }

    public func prepare(
        voiceProcessing: VoiceProcessingConfiguration,
        components: [any AudioGraphComponent]
    ) throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != voiceProcessing.isEnabled {
            try input.setVoiceProcessingEnabled(voiceProcessing.isEnabled)
        }
        if voiceProcessing.isEnabled {
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = voiceProcessing.automaticGainControl
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: ObjCBool(voiceProcessing.advancedDucking),
                duckingLevel: voiceProcessing.duckingLevel.avLevel
            )
        }
        // Touching the main mixer connects it to the output node, so the
        // engine has an output chain even before a player is attached.
        _ = engine.mainMixerNode

        do {
            for component in components {
                try component.install(on: engine)
                installed.append(component)
            }
        } catch {
            teardown()
            throw error
        }
        engine.prepare()
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    public func teardown() {
        for component in installed.reversed() {
            component.uninstall(from: engine)
        }
        installed.removeAll()
    }
}

extension VoiceProcessingConfiguration.DuckingLevel {
    var avLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level {
        switch self {
        case .default: .default
        case .min: .min
        case .mid: .mid
        case .max: .max
        }
    }
}
