/// The kind of an input or output port, mirroring `AVAudioSession.Port`
/// without depending on iOS-only API.
public enum AudioPortKind: String, Sendable, Hashable, CaseIterable {
    case builtInMic
    case builtInSpeaker
    case builtInReceiver
    case headsetMic
    case headphones
    case bluetoothHFP
    case bluetoothA2DP
    case bluetoothLE
    case airPlay
    case carAudio
    case usbAudio
    case hdmi
    case lineIn
    case lineOut
    case continuityMicrophone
    case other

    /// Any Bluetooth transport (AirPods use HFP for voice chat).
    public var isBluetooth: Bool {
        switch self {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: true
        default: false
        }
    }

    /// Ports built into the phone.
    public var isBuiltIn: Bool {
        switch self {
        case .builtInMic, .builtInSpeaker, .builtInReceiver: true
        default: false
        }
    }
}

/// One input or output port in the current route.
public struct AudioPort: Sendable, Hashable {
    public var kind: AudioPortKind
    /// The user-visible name, for example "Joe's AirPods Pro". Log it with
    /// `privacy: .private`: device names often contain the owner's name.
    public var name: String
    /// A system identifier that is stable for a given device.
    public var uid: String

    public init(kind: AudioPortKind, name: String, uid: String) {
        self.kind = kind
        self.name = name
        self.uid = uid
    }
}

/// The ports audio currently flows through.
public struct AudioRoute: Sendable, Hashable {
    public var inputs: [AudioPort]
    public var outputs: [AudioPort]

    public init(inputs: [AudioPort], outputs: [AudioPort]) {
        self.inputs = inputs
        self.outputs = outputs
    }

    /// No ports, for example before the session is first configured.
    public static let none = AudioRoute(inputs: [], outputs: [])

    /// The port audio is captured from, if any.
    public var input: AudioPort? { inputs.first }

    /// The port audio plays through, if any.
    public var output: AudioPort? { outputs.first }

    /// Whether capture or playback goes through a Bluetooth device.
    public var usesBluetooth: Bool {
        inputs.contains { $0.kind.isBluetooth } || outputs.contains { $0.kind.isBluetooth }
    }

    /// Whether playback goes through the loudspeaker, where echo
    /// cancellation matters most.
    public var usesSpeaker: Bool {
        outputs.contains { $0.kind == .builtInSpeaker }
    }

    /// Port kinds only (no device names), safe to log publicly.
    public var summary: String {
        let inputs = inputs.map(\.kind.rawValue).joined(separator: "+")
        let outputs = outputs.map(\.kind.rawValue).joined(separator: "+")
        return "\(inputs.isEmpty ? "none" : inputs) -> \(outputs.isEmpty ? "none" : outputs)"
    }
}
