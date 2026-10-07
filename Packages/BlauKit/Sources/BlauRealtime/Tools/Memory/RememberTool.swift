import BlauCore
import Foundation

/// `remember(text, about?)`: saves something the user wants kept, as a fact
/// they told (`FactOrigin.user`) (#68).
///
/// The text is stored as one self-contained sentence ("The user's sister
/// Maya lives in Lisbon"), about the entity named in `about` (found by name,
/// or created) or about the user. Saying the same thing twice keeps one
/// fact. The output echoes the stored fact with its id.
public struct RememberTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var text: String
        public var about: String?

        public init(text: String, about: String? = nil) {
            self.text = text
            self.about = about
        }
    }

    public static let name = "remember"
    public static let description = """
        Save something for future conversations as a fact the user told you. Call it when the user asks you to \
        remember something, or tells you a lasting fact about themselves or their life that they clearly want \
        kept. Don't call it for passing remarks. Afterwards, confirm briefly in your own words.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "text": .string(
                description: """
                    The fact as one short, self-contained sentence in the third person, e.g. "The user's sister \
                    Maya lives in Lisbon".
                    """),
            "about": .string(
                description:
                    "The person, company, place or project the fact is about, by name. Leave it out for the user."),
        ],
        required: ["text"],
        additionalProperties: false)
    public static let timeout: Duration = .seconds(5)

    public let backend: any MemoryToolBackend
    public let settings: MemoryToolSettings

    public init(backend: any MemoryToolBackend, settings: MemoryToolSettings = MemoryToolSettings()) {
        self.backend = backend
        self.settings = settings
    }

    public func call(arguments: Arguments) async throws -> String {
        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RealtimeToolError.invalidArguments("text is empty") }
        let about = arguments.about?.nonBlank?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fact = try await MemoryToolText.run { try await backend.remember(text, about: about) }
        return try RealtimeToolOutput.json(
            Output(
                remembered: MemoryToolFactOutput(
                    fact, timeZone: settings.timeZone(), maximumCharacters: settings.maximumResultCharacters)))
    }

    struct Output: Encodable {
        var remembered: MemoryToolFactOutput
    }
}
