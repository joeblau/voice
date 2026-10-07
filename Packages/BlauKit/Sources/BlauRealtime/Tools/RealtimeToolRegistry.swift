/// The client-side tools a realtime session offers Grok, by name.
///
/// The registry is the single list both halves of function calling read:
/// ``definitions`` go into `session.tools` (through
/// ``RealtimeSessionConfigurator/setTools(_:)``), and
/// ``RealtimeToolRunner`` looks up ``tool(named:)`` when a call arrives. A
/// value type, so the composition root builds it once (memory tools behind
/// the `memoryTools` flag, #68) and hands copies to both.
///
/// ```swift
/// var registry = RealtimeToolRegistry()
/// try registry.register(SearchMemoryTool(index: index))
/// await configurator.setTools(registry.definitions)
/// let runner = RealtimeToolRunner(registry: registry, sender: client)
/// ```
public struct RealtimeToolRegistry: Sendable {
    /// Why a tool couldn't be registered.
    public enum RegistrationError: Error, Sendable, Equatable {
        /// The name isn't 1–64 letters, digits, `_` or `-`.
        case invalidName(String)
        /// Another tool already has this name.
        case duplicateName(String)
    }

    /// The registered tools, in registration order.
    public private(set) var tools: [any RealtimeFunctionTool] = []

    public init() {}

    /// A registry with `tools`, in order.
    public init(_ tools: [any RealtimeFunctionTool]) throws(RegistrationError) {
        for tool in tools {
            try register(tool)
        }
    }

    /// Adds `tool`.
    ///
    /// - Throws: ``RegistrationError`` for a malformed or duplicate name.
    ///   The server would reject the whole `session.update` for either, so
    ///   it is caught here, at launch.
    public mutating func register(_ tool: any RealtimeFunctionTool) throws(RegistrationError) {
        let name = type(of: tool).name
        guard Self.isValidName(name) else { throw .invalidName(name) }
        guard self.tool(named: name) == nil else { throw .duplicateName(name) }
        tools.append(tool)
    }

    /// Removes the tool called `name`, if any.
    public mutating func unregister(named name: String) {
        tools.removeAll { type(of: $0).name == name }
    }

    /// The tool called `name`.
    public func tool(named name: String) -> (any RealtimeFunctionTool)? {
        tools.first { type(of: $0).name == name }
    }

    /// The registered names, in order.
    public var names: [String] { tools.map { type(of: $0).name } }

    /// Whether nothing is registered.
    public var isEmpty: Bool { tools.isEmpty }

    /// The `session.tools` entries for the registered tools, in order.
    public var definitions: [RealtimeTool] { tools.map { type(of: $0).definition } }

    /// Whether `name` is a valid function name: 1–64 ASCII letters, digits,
    /// `_` or `-` (the OpenAI-compatible rule xAI follows).
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == 0x5F || byte == 0x2D
            }
    }
}
