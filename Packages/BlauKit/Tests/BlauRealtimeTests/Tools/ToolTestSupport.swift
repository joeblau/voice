import BlauCore
import BlauRealtime
import Foundation
import Synchronization
import Testing

/// Lets a test decide when a tool call returns. Waiters don't respond to
/// cancellation unless ``CancellableGateTool`` is used, so a gate can also
/// stand in for a tool that ignores cancellation.
final class Gate: Sendable {
    private struct State {
        var opened: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var arrivals: [String] = []
    }

    private let state = Mutex(State())

    /// Keys that reached the gate, in order.
    var arrivals: [String] { state.withLock { $0.arrivals } }

    func wait(_ key: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state in
                state.arrivals.append(key)
                if state.opened.contains(key) { return true }
                state.waiters[key, default: []].append(continuation)
                return false
            }
            if isOpen { continuation.resume() }
        }
    }

    func open(_ key: String) {
        let waiters = state.withLock { state in
            state.opened.insert(key)
            return state.waiters.removeValue(forKey: key) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// `gate {"key": "a"}` waits at the gate for its key, then returns
/// `{"key": "a"}`. Ignores cancellation, like a badly behaved tool.
struct GateTool: RealtimeTypedFunctionTool {
    struct Arguments: Codable, Sendable { var key: String }

    static let name = "gate"
    static let description = "Waits for the test."
    static let parameters: JSONSchema = .object(properties: ["key": .string()], required: ["key"])

    let gate: Gate

    func call(arguments: Arguments) async throws -> String {
        await gate.wait(arguments.key)
        return try RealtimeToolOutput.json(arguments)
    }
}

/// A thread-safe list, for tools to record what happened to them.
final class CallLog<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])

    var values: [Element] { items.withLock { $0 } }

    func append(_ item: Element) {
        items.withLock { $0.append(item) }
    }
}

/// Waits for cancellation and records that it saw it.
struct CancellableTool: RealtimeFunctionTool {
    static let name = "cancellable"
    static let description = "Runs until cancelled."
    static let parameters = JSONSchema.noArguments

    let cancellations = CallLog<Bool>()

    func call(_ arguments: Data) async throws -> String {
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            cancellations.append(true)
            throw error
        }
        return "{}"
    }
}

/// A tool with a longer budget than the default.
struct PatientTool: RealtimeFunctionTool {
    static let name = "patient"
    static let description = "Takes its time."
    static let parameters = JSONSchema.noArguments
    static let timeout: Duration = .seconds(10)

    let gate: Gate

    func call(_ arguments: Data) async throws -> String {
        await gate.wait("patient")
        return #"{"done":true}"#
    }
}

/// `explode {"kind": "failed" | "other"}` throws.
struct ExplodingTool: RealtimeTypedFunctionTool {
    struct Arguments: Decodable, Sendable { var kind: String }
    struct Boom: Error {}

    static let name = "explode"
    static let description = "Always fails."
    static let parameters: JSONSchema = .object(properties: ["kind": .string()], required: ["kind"])

    func call(arguments: Arguments) async throws -> String {
        if arguments.kind == "failed" {
            throw RealtimeToolError.failed("No notes match that query.")
        }
        throw Boom()
    }
}

/// `search_memory {"query": …}` answering from a table, counting calls.
struct FakeSearchMemoryTool: RealtimeTypedFunctionTool {
    struct Arguments: Decodable, Sendable { var query: String }

    static let name = "search_memory"
    static let description = "Search what the user said before"
    static let parameters: JSONSchema = .object(properties: ["query": .string()], required: ["query"])

    let results: [String: [String]]
    let calls = CallLog<String>()

    func call(arguments: Arguments) async throws -> String {
        calls.append(arguments.query)
        return try RealtimeToolOutput.json(["results": results[arguments.query] ?? []])
    }
}

/// Builders for the server events the runner reads.
enum ToolEvents {
    static func created(_ responseID: String?) -> RealtimeServerEvent {
        .responseCreated(.init(response: RealtimeResponse(id: responseID, status: .inProgress, output: [])))
    }

    static func added(callID: String, name: String, responseID: String? = "resp_1") -> RealtimeServerEvent {
        .responseOutputItemAdded(
            .init(
                responseID: responseID,
                item: .functionCall(.init(status: .inProgress, callID: callID, name: name, arguments: nil))))
    }

    static func argumentsDone(
        _ callID: String, name: String?, arguments: String, responseID: String? = "resp_1"
    ) -> RealtimeServerEvent {
        .responseFunctionCallArgumentsDone(
            .init(responseID: responseID, callID: callID, name: name, arguments: arguments))
    }

    static func itemDone(_ callID: String, name: String, arguments: String, responseID: String? = "resp_1")
        -> RealtimeServerEvent
    {
        .responseOutputItemDone(.init(responseID: responseID, item: functionCall(callID, name: name, arguments)))
    }

    static func functionCall(_ callID: String, name: String, _ arguments: String) -> RealtimeItem {
        .functionCall(.init(status: .completed, callID: callID, name: name, arguments: arguments))
    }

    static func done(
        _ responseID: String?, status: RealtimeResponseStatus = .completed, output: [RealtimeItem] = []
    ) -> RealtimeServerEvent {
        .responseDone(.init(response: RealtimeResponse(id: responseID, status: status, output: output)))
    }
}

extension RecordingSender {
    /// The `function_call_output`s sent, as (call id, output).
    var outputs: [(callID: String, output: String)] {
        sent.compactMap { event in
            guard case .conversationItemCreate(.functionCallOutput(let output), _) = event else { return nil }
            return (output.callID, output.output)
        }
    }

    /// How many `response.create`s were sent.
    var responseCreates: Int {
        sent.count { event in
            if case .responseCreate = event { true } else { false }
        }
    }

    func waitForSent(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil("\(count) sent events (have \(sent.count))", sourceLocation: sourceLocation) {
            self.sent.count >= count
        }
    }
}

/// Decodes a tool's JSON output for checking.
func outputObject(_ output: String) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
}
