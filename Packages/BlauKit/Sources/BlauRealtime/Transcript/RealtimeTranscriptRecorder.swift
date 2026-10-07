import BlauCore
import Foundation
import Synchronization

/// Records every frame a ``RealtimeClient`` sends and receives, with
/// connects and closes, into a ``RealtimeTranscript``.
///
/// Pass one to the client to capture a session, then save
/// ``transcript`` as a test fixture:
///
/// ```swift
/// let recorder = RealtimeTranscriptRecorder(metadata: ["note": "manual text turn"])
/// let client = RealtimeClient(endpoint: url, tokenProvider: tokens, recorder: recorder)
/// // ... run the session ...
/// try recorder.transcript.write(to: fixtureURL)
/// ```
///
/// Recording is opt-in and meant for development: a transcript holds what
/// was said and the audio. It never holds the client secret.
public final class RealtimeTranscriptRecorder: Sendable {
    private struct State {
        var origin: Duration?
        var transcript: RealtimeTranscript
    }

    private let clock: any BlauClock
    private let state: Mutex<State>

    public init(clock: any BlauClock = SystemClock(), metadata: [String: JSONValue] = [:]) {
        self.clock = clock
        self.state = Mutex(State(transcript: RealtimeTranscript(metadata: metadata)))
    }

    /// Everything recorded so far.
    public var transcript: RealtimeTranscript {
        state.withLock { $0.transcript }
    }

    /// Appends one entry, timed from the first entry recorded.
    public func record(_ direction: RealtimeTranscript.Direction, _ payload: RealtimeTranscript.Payload) {
        let now = clock.uptime
        state.withLock { state in
            let origin = state.origin ?? now
            state.origin = origin
            state.transcript.entries.append(.init(offset: now - origin, direction: direction, payload: payload))
        }
    }

    /// Drops everything recorded so far.
    public func reset() {
        state.withLock { state in
            state.origin = nil
            state.transcript.entries.removeAll()
        }
    }
}
