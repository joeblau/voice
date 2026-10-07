/// Returns its `text` argument unchanged: `{"text": "…"}`.
///
/// The smallest real tool, for checking the function-calling round trip end
/// to end (the `echo-tool` fixture, and a live session with a real key). The
/// app doesn't register it.
public struct EchoTool: RealtimeTypedFunctionTool {
    public struct Arguments: Codable, Sendable, Hashable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public static let name = "echo"
    public static let description =
        "Repeats the given text back exactly. Use it only when the user asks you to test the echo tool."
    public static let parameters: JSONSchema = .object(
        properties: ["text": .string(description: "The text to repeat.")],
        required: ["text"],
        additionalProperties: false)

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        try RealtimeToolOutput.json(arguments)
    }
}
