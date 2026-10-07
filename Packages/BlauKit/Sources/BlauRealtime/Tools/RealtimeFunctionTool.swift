import Foundation

/// A client-side tool Grok can call during a realtime session: memory
/// search, collections, and anything else that runs on the device (#38).
///
/// A tool declares itself once, statically: its ``name``, a ``description``
/// that tells the model when to use it, and the JSON Schema of its
/// arguments. ``RealtimeToolRegistry`` turns those into `session.tools`, and
/// ``RealtimeToolRunner`` calls ``call(_:)`` when the model asks for it.
///
/// ```swift
/// struct SearchMemoryTool: RealtimeFunctionTool {
///     static let name = "search_memory"
///     static let description = "Search what the user said in earlier conversations."
///     static let parameters: JSONSchema = .object(
///         properties: ["query": .string(description: "What to look for.")], required: ["query"])
///
///     func call(_ arguments: Data) async throws -> String { … }
/// }
/// ```
///
/// - **Arguments** arrive as the raw JSON the model produced (the
///   `arguments` of `response.function_call_arguments.done`). They are
///   model output: validate them. ``RealtimeTypedFunctionTool`` decodes them
///   for you.
/// - **The result** is the `output` of the `function_call_output` item,
///   usually a JSON object (``RealtimeToolOutput/json(_:)``). Keep it small:
///   it becomes conversation context and costs tokens on every later turn.
/// - **Time.** A call has ``timeout`` (3 s by default) before the runner
///   answers for it with a timeout error and cancels the task. Check for
///   cancellation in long work.
/// - **Errors.** Throw ``RealtimeToolError/failed(_:)`` with a message for
///   the model ("No notes match that query"). Any other error is reported to
///   the model generically and logged by type only.
///
/// Named `RealtimeFunctionTool` rather than `RealtimeTool`: ``RealtimeTool``
/// is the wire format of a `session.tools` entry (#34).
public protocol RealtimeFunctionTool: Sendable {
    /// The function name the model calls: 1–64 letters, digits, `_` or `-`.
    static var name: String { get }
    /// When and why to use the tool, written for the model.
    static var description: String { get }
    /// The JSON Schema of the arguments object.
    static var parameters: JSONSchema { get }
    /// How long one call may take before the runner gives up on it.
    static var timeout: Duration { get }

    /// Runs the tool.
    ///
    /// - Parameter arguments: The model's arguments, a JSON object as UTF-8.
    /// - Returns: The output to send back to the model (usually JSON).
    func call(_ arguments: Data) async throws -> String
}

extension RealtimeFunctionTool {
    /// The default call budget, ``RealtimeToolRunner/Configuration/defaultTimeout``.
    public static var timeout: Duration { RealtimeToolRunner.Configuration.defaultTimeout }

    /// The `session.tools` entry for this tool.
    public static var definition: RealtimeTool {
        .function(name: name, description: description, parameters: parameters.json)
    }
}

/// A ``RealtimeFunctionTool`` whose arguments are decoded into a type.
///
/// ```swift
/// struct EchoTool: RealtimeTypedFunctionTool {
///     struct Arguments: Decodable, Sendable { var text: String }
///     …
///     func call(arguments: Arguments) async throws -> String { … }
/// }
/// ```
///
/// Arguments that aren't valid JSON or don't match `Arguments` become
/// ``RealtimeToolError/invalidArguments(_:)``, which tells the model what
/// was wrong without the tool running.
public protocol RealtimeTypedFunctionTool: RealtimeFunctionTool {
    associatedtype Arguments: Decodable & Sendable

    func call(arguments: Arguments) async throws -> String
}

extension RealtimeTypedFunctionTool {
    public func call(_ arguments: Data) async throws -> String {
        let decoded: Arguments
        do {
            // Some models send "" for a function without parameters.
            let isBlank = String(decoding: arguments, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let json = isBlank ? Data("{}".utf8) : arguments
            decoded = try JSONDecoder().decode(Arguments.self, from: json)
        } catch {
            throw RealtimeToolError.invalidArguments(RealtimeEventCoding.describe(error))
        }
        return try await call(arguments: decoded)
    }
}

/// Errors a tool throws to tell the model what went wrong.
public enum RealtimeToolError: Error, Sendable, Equatable {
    /// The arguments didn't parse or didn't make sense. The reason is shown
    /// to the model so it can retry; never include user content in it.
    case invalidArguments(String)
    /// The tool ran but couldn't do what was asked. The message is shown to
    /// the model, e.g. "No notes match that query."
    case failed(String)
}

/// Helpers for building tool output.
public enum RealtimeToolOutput {
    /// `value` as compact JSON with sorted keys, so the same result always
    /// produces the same output.
    public static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The output sent when a call couldn't produce a result:
    /// `{"error": "<code>", "message": "<message>"}`.
    public static func error(_ code: String, message: String) -> String {
        (try? json(["error": code, "message": message])) ?? #"{"error":"\#(code)"}"#
    }
}
