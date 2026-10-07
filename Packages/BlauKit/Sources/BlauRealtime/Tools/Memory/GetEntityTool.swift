import BlauCore
import Foundation

/// `get_entity(name)`: everything memory knows about one person, company,
/// place or project, as a timeline of facts (#68).
///
/// Facts come oldest first with when each became true (`since`) and, for
/// ones that no longer hold, until when, so Grok can tell "Alex worked at
/// Stripe until June, then joined Field Office". The best match is
/// described; other entities with a similar name are listed by name in
/// `also_matching`. Over the output budget, the oldest facts are left out
/// first (counted in `earlier_facts_omitted`).
public struct GetEntityTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    public static let name = "get_entity"
    public static let description = """
        Everything memory knows about one person, company, place or project, by name: its aliases and a \
        timeline of facts about it, including ones that are no longer true. Use it when the user asks what you \
        know about someone or something specific, or how it has changed.
        """
    public static let parameters: JSONSchema = .object(
        properties: ["name": .string(description: "The name, e.g. \"Alex\" or \"Acme\".")],
        required: ["name"],
        additionalProperties: false)

    public let backend: any MemoryToolBackend
    public let settings: MemoryToolSettings

    public init(backend: any MemoryToolBackend, settings: MemoryToolSettings = MemoryToolSettings()) {
        self.backend = backend
        self.settings = settings
    }

    public func call(arguments: Arguments) async throws -> String {
        let name = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RealtimeToolError.invalidArguments("name is empty") }
        let matches = try await MemoryToolText.run { try await backend.entities(named: name, limit: 4) }
        return Self.output(for: matches, settings: settings)
    }

    struct Output: Encodable {
        struct Entity: Encodable {
            var name: String
            var type: String?
            var aliases: [String]?
            var summary: String?
            var facts: [MemoryToolFactOutput]
            var earlierFactsOmitted: Int?

            enum CodingKeys: String, CodingKey {
                case name, type, aliases, summary, facts
                case earlierFactsOmitted = "earlier_facts_omitted"
            }
        }

        var entity: Entity?
        var alsoMatching: [String]?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case entity
            case alsoMatching = "also_matching"
            case message
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // `"entity": null` tells the model plainly that nothing matched.
            try container.encode(entity, forKey: .entity)
            try container.encodeIfPresent(alsoMatching, forKey: .alsoMatching)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }

    static func output(for matches: [MemoryToolEntity], settings: MemoryToolSettings) -> String {
        guard let best = matches.first else {
            return encode(
                Output(
                    entity: nil,
                    message: "Memory doesn't know anyone or anything by that name. Try search_memory instead."))
        }
        let timeZone = settings.timeZone()
        let others = matches.dropFirst().map(\.name)
        var facts = best.facts.map {
            MemoryToolFactOutput($0, timeZone: timeZone, maximumCharacters: settings.maximumResultCharacters)
        }
        var omitted = 0
        func make() -> Output {
            Output(
                entity: Output.Entity(
                    name: best.name, type: best.type, aliases: best.aliases.isEmpty ? nil : best.aliases,
                    summary: best.summary.map { MemoryToolText.clipped($0, to: settings.maximumResultCharacters) },
                    facts: facts, earlierFactsOmitted: omitted > 0 ? omitted : nil),
                alsoMatching: others.isEmpty ? nil : Array(others),
                message: facts.isEmpty && omitted == 0 ? "Memory knows the name but no facts about it yet." : nil)
        }
        var output = encode(make())
        // The newest facts matter most: drop from the start of the timeline.
        while !settings.fits(output), !facts.isEmpty {
            facts.removeFirst()
            omitted += 1
            output = encode(make())
        }
        return output
    }

    static func encode(_ output: Output) -> String {
        (try? RealtimeToolOutput.json(output)) ?? #"{"entity":null}"#
    }
}
