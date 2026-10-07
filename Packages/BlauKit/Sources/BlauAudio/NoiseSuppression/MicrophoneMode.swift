import Foundation

#if canImport(AVFoundation) && !os(watchOS) && !os(visionOS)
    import AVFoundation
#endif

/// The system microphone mode the user picks in Control Center while an app
/// records: the system applies it inside voice processing, before Blau sees
/// the audio.
///
/// #51 decided against prompting for Voice Isolation (its model hurt
/// streaming ASR on the noisy fixtures, docs/noise-suppression.md); Blau
/// reads the mode so on-device evaluations and diagnostics can record which
/// one was in effect.
public enum MicrophoneMode: String, CaseIterable, Codable, Sendable {
    /// Voice processing's own echo cancellation and noise suppression.
    case standard
    /// Apple's voice isolation on top: background sound attenuated hard.
    case voiceIsolation
    /// Processing minimized to keep every sound in the room.
    case wideSpectrum
}

/// Reads the microphone mode and opens the system picker. A protocol so
/// callers can be tested without AVFoundation.
public protocol MicrophoneModeSource: Sendable {
    /// What the user selected in Control Center.
    var preferredMode: MicrophoneMode { get }
    /// What is in effect on the current route (a route that can't isolate
    /// voice falls back to standard).
    var activeMode: MicrophoneMode { get }
    /// Opens Control Center's microphone mode module. Returns at once.
    @MainActor func showModePicker()
}

#if canImport(AVFoundation) && !os(watchOS) && !os(visionOS) && !os(tvOS)
    /// `AVCaptureDevice`'s class-level microphone mode properties and
    /// `showSystemUserInterface(.microphoneModes)`.
    public struct SystemMicrophoneModeSource: MicrophoneModeSource {
        public init() {}

        public var preferredMode: MicrophoneMode { MicrophoneMode(AVCaptureDevice.preferredMicrophoneMode) }
        public var activeMode: MicrophoneMode { MicrophoneMode(AVCaptureDevice.activeMicrophoneMode) }

        @MainActor public func showModePicker() {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }
    }

    extension MicrophoneMode {
        init(_ mode: AVCaptureDevice.MicrophoneMode) {
            switch mode {
            case .voiceIsolation: self = .voiceIsolation
            case .wideSpectrum: self = .wideSpectrum
            default: self = .standard
            }
        }
    }
#endif
