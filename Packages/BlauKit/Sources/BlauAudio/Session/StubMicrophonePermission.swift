import Synchronization

/// Microphone permission that never touches the system: a fixed status and
/// a scripted answer to the prompt. Previews, UI-test launches and unit tests
/// use it, so they never show the real permission alert (the onboarding UI
/// tests pick one with `BLAU_UI_TEST_MICROPHONE`).
public final class StubMicrophonePermission: MicrophonePermissionProvider {
    private struct State {
        var status: MicrophonePermission
        var answer: Bool
        var requests = 0
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - status: The status before any prompt.
    ///   - answer: What the user answers when an undetermined permission is
    ///     requested.
    public init(_ status: MicrophonePermission = .granted, answer: Bool = true) {
        state = Mutex(State(status: status, answer: answer))
    }

    public var status: MicrophonePermission { state.withLock { $0.status } }

    /// How many times ``request()`` was called.
    public var requests: Int { state.withLock { $0.requests } }

    /// Answers like the system: an undetermined permission takes the
    /// scripted answer; a decided one is returned as is, with no prompt.
    public func request() async -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.status == .undetermined {
                state.status = state.answer ? .granted : .denied
            }
            return state.status == .granted
        }
    }

    /// Changes the status, as the user would in the Settings app.
    public func set(_ status: MicrophonePermission) {
        state.withLock { $0.status = status }
    }
}
