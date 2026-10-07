import AVFAudio

/// Microphone permission from `AVAudioApplication` (iOS 17+, macOS 14+).
/// The prompt text is `NSMicrophoneUsageDescription` in the app's
/// Info.plist.
public struct SystemMicrophonePermission: MicrophonePermissionProvider {
    public init() {}

    public var status: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    public func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
