import Synchronization
import os

/// Where a `Signposter` sends its intervals and events.
///
/// Production uses `OSSignpostBackend`, which emits `os_signpost` records
/// that Instruments shows. Tests use `RecordingSignpostBackend` to check that
/// code begins and ends the intervals it should. The seam also leaves room
/// for an in-process consumer such as the debug performance HUD.
public protocol SignpostBackend: Sendable {
    /// Whether anything is listening. When `false`, `Signposter` skips the
    /// backend entirely and only runs the measured work.
    var isEnabled: Bool { get }

    /// Starts an interval and returns the token that ends it.
    func beginInterval(_ name: StaticString) -> SignpostIntervalToken

    /// Ends the interval `token` came from. Called at most once per token.
    func endInterval(_ name: StaticString, _ token: SignpostIntervalToken)

    /// Emits a point-in-time event.
    func emitEvent(_ name: StaticString)

    /// Ends the interval `token` came from with a public end message, for
    /// example the type of the event an interval handled. Called at most
    /// once per token, instead of ``endInterval(_:_:)``.
    ///
    /// The default implementation drops the message and calls
    /// ``endInterval(_:_:)``.
    func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String)
}

extension SignpostBackend {
    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String) {
        endInterval(name, token)
    }
}

/// Identifies one open interval. Overlapping intervals with the same name
/// (for example `asr.chunk` on two tasks) get different tokens, so
/// Instruments pairs each end with the right begin.
public struct SignpostIntervalToken: Sendable {
    /// The interval's signpost ID (or a backend-defined identifier).
    public let id: UInt64

    /// The `os` state for intervals from `OSSignpostBackend`.
    let state: OSSignpostIntervalState?

    /// A token for a custom backend.
    public init(id: UInt64) {
        self.id = id
        self.state = nil
    }

    init(state: OSSignpostIntervalState, id: OSSignpostID) {
        self.id = id.rawValue
        self.state = state
    }
}

// MARK: - OSSignpostBackend

/// Emits real `os_signpost` intervals and events through an `OSSignposter`.
///
/// Every interval gets its own signpost ID (`makeSignpostID()`) rather than
/// `.exclusive`, so intervals that overlap or that begin and end on
/// different threads (anything around an `await`) still pair up correctly.
public struct OSSignpostBackend: SignpostBackend {
    /// The underlying signposter. Use it directly when an interval needs
    /// metadata (`beginInterval(_:id:_:)` with a message), which the `os`
    /// module only accepts when built at the call site.
    public let signposter: OSSignposter

    public init(_ signposter: OSSignposter) {
        self.signposter = signposter
    }

    /// A signposter in Blau's subsystem for `category`.
    public init(category: LogCategory) {
        self.init(OSSignposter(subsystem: Log.subsystem, category: category.rawValue))
    }

    /// A backend over `OSSignposter.disabled`: every call is a no-op.
    public static var disabled: OSSignpostBackend {
        OSSignpostBackend(.disabled)
    }

    public var isEnabled: Bool { signposter.isEnabled }

    public func beginInterval(_ name: StaticString) -> SignpostIntervalToken {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        return SignpostIntervalToken(state: state, id: id)
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken) {
        // A token from another backend has no os state; there's nothing to end.
        guard let state = token.state else { return }
        signposter.endInterval(name, state)
    }

    public func emitEvent(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// The message is metadata Blau generates (an event type, a count), never
    /// user content, so it is public.
    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String) {
        guard let state = token.state else { return }
        signposter.endInterval(name, state, "\(message, privacy: .public)")
    }
}

// MARK: - RecordingSignpostBackend

/// Records every interval and event in memory. For tests that check
/// instrumentation: inject `Signposter(category:backend:)` with one of these
/// and inspect `records` or `openIntervals` afterwards.
public final class RecordingSignpostBackend: SignpostBackend {
    /// One call the backend received.
    public enum Record: Hashable, Sendable {
        case begin(name: String, id: UInt64)
        case end(name: String, id: UInt64)
        case event(name: String)
    }

    private struct State {
        var isEnabled: Bool
        var nextID: UInt64 = 1
        var records: [Record] = []
        var open: [UInt64: String] = [:]
        var endMessages: [UInt64: String] = [:]
    }

    private let state: Mutex<State>

    /// - Parameter isEnabled: Pass `false` to simulate signposting being off.
    public init(isEnabled: Bool = true) {
        state = Mutex(State(isEnabled: isEnabled))
    }

    public var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

    /// Everything received so far, in order.
    public var records: [Record] { state.withLock { $0.records } }

    /// Names of intervals that were begun and not yet ended, sorted.
    public var openIntervals: [String] { state.withLock { $0.open.values.sorted() } }

    /// Names of intervals that were begun and ended, in the order they ended.
    public var completedIntervals: [String] {
        records.compactMap { record in
            if case .end(let name, _) = record { name } else { nil }
        }
    }

    /// Names of the events emitted, in order.
    public var events: [String] {
        records.compactMap { record in
            if case .event(let name) = record { name } else { nil }
        }
    }

    public func beginInterval(_ name: StaticString) -> SignpostIntervalToken {
        let name = name.description
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.records.append(.begin(name: name, id: id))
            state.open[id] = name
            return id
        }
        return SignpostIntervalToken(id: id)
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken) {
        let name = name.description
        state.withLock { state in
            state.records.append(.end(name: name, id: token.id))
            state.open[token.id] = nil
        }
    }

    public func emitEvent(_ name: StaticString) {
        let name = name.description
        state.withLock { $0.records.append(.event(name: name)) }
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String) {
        endInterval(name, token)
        state.withLock { $0.endMessages[token.id] = message }
    }

    /// The end messages of the intervals named `name` that ended with one,
    /// in the order they ended.
    public func endMessages(of name: String) -> [String] {
        state.withLock { state in
            state.records.compactMap { record in
                guard case .end(let ended, let id) = record, ended == name else { return nil }
                return state.endMessages[id]
            }
        }
    }
}
