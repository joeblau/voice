import BlauCore
import Foundation
import Synchronization

// Function calling inside a turn (#38, #68). The orchestrator owns the
// session's `RealtimeToolRunner`: it passes the runner every server event
// after handling it itself, in order, and tells it to drop everything on
// barge-in and on each new connection. A response that ends with function
// calls doesn't end its turn: the turn waits for the tool results and
// carries on with the follow-up response, which the runner asks for through
// the orchestrator (`ToolEventRouter`) so it goes out tagged with the turn,
// like any `response.create`.

/// What the orchestrator passes on to the tool runner, in the order it
/// decided it.
enum ToolFeedItem: Sendable {
    case event(RealtimeServerEvent)
    case cancelAll
}

/// The tool runner's sender: function outputs go straight to the client;
/// the follow-up `response.create` goes through the orchestrator, which
/// tags it with the turn waiting for it and holds it while another response
/// is active.
final class ToolEventRouter: RealtimeEventSending {
    private struct Owner {
        weak var orchestrator: TurnOrchestrator?
    }

    let client: RealtimeClient
    private let owner = Mutex(Owner())

    init(client: RealtimeClient) {
        self.client = client
    }

    func attach(_ orchestrator: TurnOrchestrator) {
        owner.withLock { $0.orchestrator = orchestrator }
    }

    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        guard case .responseCreate = event else {
            try await client.send(event)
            return
        }
        guard let orchestrator = owner.withLock({ $0.orchestrator }) else { throw .cancelled }
        try await orchestrator.requestToolFollowUp()
    }
}

extension TurnSnapshot {
    /// One function call Grok made in this conversation, for the chat's
    /// tool chips (#68).
    public struct ToolCall: Sendable, Hashable, Identifiable {
        /// The model's call id.
        public var id: String
        /// A stable row id for the chat transcript.
        public var rowID: UUID
        /// The function name the model used, e.g. `search_memory`.
        public var name: String
        /// When the call started (wall clock).
        public var startedAt: Date
        /// How it ended; `nil` while it runs.
        public var outcome: RealtimeToolRunner.Outcome?
        /// The model's arguments and the tool's output. Only kept when the
        /// orchestrator keeps tool payloads (DEBUG builds); they are user
        /// content.
        public var arguments: String?
        public var output: String?
        /// Whether the call belongs to the turn in progress. The chat shows
        /// live calls with the reply as it plays.
        public var isLive: Bool

        public init(
            id: String, rowID: UUID = UUID(), name: String, startedAt: Date,
            outcome: RealtimeToolRunner.Outcome? = nil, arguments: String? = nil, output: String? = nil,
            isLive: Bool = false
        ) {
            self.id = id
            self.rowID = rowID
            self.name = name
            self.startedAt = startedAt
            self.outcome = outcome
            self.arguments = arguments
            self.output = output
            self.isLive = isLive
        }

        /// Whether it is still running.
        public var isRunning: Bool { outcome == nil }
    }
}

extension TurnOrchestrator {
    /// The most tool calls a snapshot lists (the newest).
    static let maximumToolCallRecords = 64

    /// A tool call with the turn it was made in.
    struct ToolCallEntry {
        var call: TurnSnapshot.ToolCall
        var turn: Int?
    }

    /// The call ids of the function calls in `output`.
    static func functionCallIDs(in output: [RealtimeItem]) -> Set<String> {
        Set(
            output.compactMap { item in
                if case .functionCall(let call) = item { call.callID } else { nil }
            })
    }

    /// Whether the tool runner needs `event`: responses starting and
    /// ending, function calls, and errors (a rejected follow-up). Audio and
    /// transcript deltas aren't passed on.
    static func concernsTools(_ event: RealtimeServerEvent) -> Bool {
        switch event {
        case .responseCreated, .responseOutputItemAdded, .responseFunctionCallArgumentsDone,
            .responseOutputItemDone, .responseDone, .error:
            true
        default:
            false
        }
    }

    /// Whether a response that ended with `status` and made calls goes on
    /// with their results: the runner runs the calls of completed and
    /// incomplete responses and drops those of cancelled and failed ones.
    static func continuesWithTools(_ status: RealtimeResponseStatus?) -> Bool {
        status == nil || status == .completed || status == .incomplete
    }
}
