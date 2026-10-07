import BlauCore
import Foundation
import Synchronization

/// `forget(id, confirm?)`: forgets a fact, only after the user confirms out
/// loud (#68).
///
/// Two calls, with the user speaking in between:
///
/// 1. `forget(id)` looks the fact up and changes nothing. The output is the
///    fact and `"status": "needs_confirmation"`, with an instruction to read
///    it back and ask.
/// 2. Once the user says yes, `forget(id, confirm: true)` invalidates it
///    (facts are add-only and validity-dated, so it stops being true from
///    now on and leaves ordinary searches) and answers `"forgotten"`.
///
/// The confirming call is only accepted in a later tool chain than the one
/// that asked (``RealtimeToolCallContext/chain``): the user has spoken
/// since, so Grok can't confirm on its own in a follow-up. A request
/// expires after ``MemoryToolSettings/confirmationLifetime``.
public struct ForgetTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var id: String
        public var confirm: Bool?

        public init(id: String, confirm: Bool? = nil) {
            self.id = id
            self.confirm = confirm
        }
    }

    public static let name = "forget"
    public static let description = """
        Forget a fact from memory, only after the user confirms out loud. First call it with the fact's id (from \
        search_memory or get_entity): it changes nothing and returns the fact. Read the fact back and ask the user \
        whether to forget it. Only after they say yes, call it again with the same id and confirm set to true.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "id": .string(description: "The id of the fact to forget, from search_memory or get_entity."),
            "confirm": .boolean(description: "true only after the user said yes to forgetting this fact."),
        ],
        required: ["id"],
        additionalProperties: false)
    public static let timeout: Duration = .seconds(5)

    public let backend: any MemoryToolBackend
    public let settings: MemoryToolSettings
    /// Confirmations asked for and not given yet. Shared by copies of the
    /// tool (the registry is a value), so one session's requests are seen
    /// by every call.
    let confirmations: ForgetConfirmations

    public init(backend: any MemoryToolBackend, settings: MemoryToolSettings = MemoryToolSettings()) {
        self.backend = backend
        self.settings = settings
        confirmations = ForgetConfirmations()
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let id = UUID(uuidString: arguments.id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RealtimeToolError.invalidArguments("id must be a fact id from search_memory or get_entity")
        }
        guard let fact = try await MemoryToolText.run({ try await backend.fact(id) }) else {
            throw RealtimeToolError.failed(
                "No fact has that id. Only facts can be forgotten; find one with search_memory or get_entity.")
        }
        let timeZone = settings.timeZone()
        let maximum = settings.maximumResultCharacters
        guard fact.isCurrent else {
            confirmations.remove(id)
            return try Self.encode(
                Output(
                    status: "already_forgotten",
                    fact: MemoryToolFactOutput(fact, timeZone: timeZone, maximumCharacters: maximum)))
        }
        let chain = RealtimeToolCallContext.current?.chain
        let now = settings.clock.uptime
        if arguments.confirm == true,
            confirmations.take(id, confirmedIn: chain, at: now, lifetime: settings.confirmationLifetime)
        {
            guard let forgotten = try await MemoryToolText.run({ try await backend.forget(id) }) else {
                throw RealtimeToolError.failed("That fact is gone already.")
            }
            return try Self.encode(
                Output(
                    status: "forgotten",
                    fact: MemoryToolFactOutput(forgotten, timeZone: timeZone, maximumCharacters: maximum)))
        }
        confirmations.request(id, in: chain, at: now)
        return try Self.encode(
            Output(
                status: "needs_confirmation",
                fact: MemoryToolFactOutput(fact, timeZone: timeZone, maximumCharacters: maximum),
                instruction: """
                    Nothing was forgotten yet. Read this fact back to the user and ask whether to forget it. Only \
                    if they say yes, call forget again with this id and confirm set to true.
                    """))
    }

    struct Output: Encodable {
        var status: String
        var fact: MemoryToolFactOutput
        var instruction: String?
    }

    static func encode(_ output: Output) throws -> String {
        try RealtimeToolOutput.json(output)
    }
}

/// The `forget` confirmations one session has asked for: fact id → the tool
/// chain that asked and when (uptime).
final class ForgetConfirmations: Sendable {
    private struct Request {
        var chain: Int?
        var at: Duration
    }

    private let requests = Mutex<[UUID: Request]>([:])

    /// Records that the user is being asked about `id` in `chain`.
    func request(_ id: UUID, in chain: Int?, at now: Duration) {
        requests.withLock { $0[id] = Request(chain: chain, at: now) }
    }

    /// Whether a confirmation of `id` in `chain` answers a request: one was
    /// made in an earlier chain, at most `lifetime` ago. An accepted
    /// confirmation is used up.
    func take(_ id: UUID, confirmedIn chain: Int?, at now: Duration, lifetime: Duration) -> Bool {
        requests.withLock { requests in
            guard let request = requests[id], now - request.at <= lifetime,
                let asked = request.chain, let chain, chain > asked
            else { return false }
            requests[id] = nil
            return true
        }
    }

    func remove(_ id: UUID) {
        requests.withLock { $0[id] = nil }
    }
}
