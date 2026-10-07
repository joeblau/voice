import Foundation

/// A tool call as the chat transcript shows it (#68): a subtle chip such as
/// "Searched memory" between the user's question and Grok's answer. DEBUG
/// builds keep the call's arguments and output, shown when the chip is
/// tapped.
///
/// Chips live in memory only, for the conversation on screen (the store has
/// no record of tool calls).
public struct ChatToolCall: Identifiable, Hashable, Sendable {
    /// The model's call id.
    public var id: String
    /// The chip's row id.
    public var rowID: UUID
    /// The function name, e.g. `search_memory`.
    public var name: String
    public var startedAt: Date
    public var state: State
    /// The arguments and output, when the orchestrator kept them (DEBUG).
    public var arguments: String?
    public var output: String?

    public enum State: Hashable, Sendable {
        case running
        case succeeded
        case failed
    }

    public init(
        id: String, rowID: UUID = UUID(), name: String, startedAt: Date, state: State, arguments: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.rowID = rowID
        self.name = name
        self.startedAt = startedAt
        self.state = state
        self.arguments = arguments
        self.output = output
    }

    /// The chip for one of the orchestrator's calls.
    public init(_ call: TurnSnapshot.ToolCall) {
        let state: State =
            switch call.outcome {
            case nil: .running
            case .succeeded?: .succeeded
            default: .failed
            }
        self.init(
            id: call.id, rowID: call.rowID, name: call.name, startedAt: call.startedAt, state: state,
            arguments: call.arguments, output: call.output)
    }

    /// What the chip says: "Searching memory…", "Searched memory",
    /// "Couldn't search memory".
    public var title: String {
        let phrases: (running: String, done: String, failed: String) =
            switch name {
            case "search_memory": ("Searching memory…", "Searched memory", "Couldn't search memory")
            case "get_entity": ("Checking memory…", "Checked memory", "Couldn't check memory")
            case "remember": ("Saving to memory…", "Saved to memory", "Couldn't save to memory")
            case "forget": ("Updating memory…", "Updated memory", "Couldn't update memory")
            default: ("Using \(name)…", "Used \(name)", "\(name) failed")
            }
        switch state {
        case .running: return phrases.running
        case .succeeded: return phrases.done
        case .failed: return phrases.failed
        }
    }

    /// The arguments and output, for the DEBUG payload view; `nil` when
    /// they weren't kept.
    public var payload: String? {
        guard arguments != nil || output != nil else { return nil }
        return """
            \(name)
            arguments: \(arguments ?? "-")
            output: \(output ?? "-")
            """
    }
}
