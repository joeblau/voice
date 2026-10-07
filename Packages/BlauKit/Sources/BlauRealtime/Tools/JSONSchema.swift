/// A JSON Schema describing a function tool's arguments: the `parameters`
/// of a `{"type": "function", …}` tool in `session.tools`.
///
/// Build one from the typed constructors, which cover what Grok's function
/// calling uses (objects of strings, numbers, booleans, enums and arrays),
/// or wrap any schema with ``init(json:)``:
///
/// ```swift
/// static let parameters: JSONSchema = .object(
///     properties: [
///         "query": .string(description: "What to look for, in the user's words."),
///         "limit": .integer(description: "How many results.", minimum: 1, maximum: 10),
///     ],
///     required: ["query"])
/// ```
///
/// On the wire it is the plain JSON object; `RealtimeEventCoding` sorts
/// keys, so the same schema always encodes to the same bytes.
public struct JSONSchema: Sendable, Hashable, Codable {
    /// The schema as JSON.
    public var json: JSONValue

    /// Wraps a schema written by hand.
    public init(json: JSONValue) {
        self.json = json
    }

    public init(from decoder: any Decoder) throws {
        json = try JSONValue(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    // MARK: Constructors

    /// An object with named properties.
    ///
    /// - Parameters:
    ///   - properties: Each property's schema.
    ///   - required: Properties the model must always pass, in the order
    ///     given.
    ///   - description: What the object is.
    ///   - additionalProperties: `false` forbids properties not listed.
    ///     `nil` leaves it to the schema default.
    public static func object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil,
        additionalProperties: Bool? = nil
    ) -> JSONSchema {
        var object: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties.mapValues(\.json)),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map(JSONValue.string))
        }
        object["description"] = description.map(JSONValue.string)
        object["additionalProperties"] = additionalProperties.map(JSONValue.bool)
        return JSONSchema(json: .object(object))
    }

    /// A string, optionally limited to `values`.
    public static func string(description: String? = nil, enum values: [String]? = nil) -> JSONSchema {
        var object: [String: JSONValue] = ["type": "string"]
        object["description"] = description.map(JSONValue.string)
        object["enum"] = values.map { .array($0.map(JSONValue.string)) }
        return JSONSchema(json: .object(object))
    }

    /// A whole number, optionally bounded.
    public static func integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var object: [String: JSONValue] = ["type": "integer"]
        object["description"] = description.map(JSONValue.string)
        object["minimum"] = minimum.map { .number(Double($0)) }
        object["maximum"] = maximum.map { .number(Double($0)) }
        return JSONSchema(json: .object(object))
    }

    /// A number, optionally bounded.
    public static func number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil)
        -> JSONSchema
    {
        var object: [String: JSONValue] = ["type": "number"]
        object["description"] = description.map(JSONValue.string)
        object["minimum"] = minimum.map(JSONValue.number)
        object["maximum"] = maximum.map(JSONValue.number)
        return JSONSchema(json: .object(object))
    }

    /// `true` or `false`.
    public static func boolean(description: String? = nil) -> JSONSchema {
        var object: [String: JSONValue] = ["type": "boolean"]
        object["description"] = description.map(JSONValue.string)
        return JSONSchema(json: .object(object))
    }

    /// An array whose elements match `items`.
    public static func array(of items: JSONSchema, description: String? = nil, maximumCount: Int? = nil)
        -> JSONSchema
    {
        var object: [String: JSONValue] = ["type": "array", "items": items.json]
        object["description"] = description.map(JSONValue.string)
        object["maxItems"] = maximumCount.map { .number(Double($0)) }
        return JSONSchema(json: .object(object))
    }

    /// A function that takes no arguments: an object with no properties.
    public static let noArguments = JSONSchema.object(properties: [:])
}
