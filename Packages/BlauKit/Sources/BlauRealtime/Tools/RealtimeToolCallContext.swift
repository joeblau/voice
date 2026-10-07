/// Where a tool call came from, for the few tools that care: available as
/// ``current`` while ``RealtimeToolRunner`` runs a tool.
///
/// ```swift
/// func call(arguments: Arguments) async throws -> String {
///     let chain = RealtimeToolCallContext.current?.chain
///     …
/// }
/// ```
///
/// `forget` (#68) uses ``chain`` to require a spoken confirmation: the call
/// that confirms has to come in a later chain than the call that asked, so
/// the user said something in between. A tool called outside the runner
/// (a test calling it directly) sees `nil`.
public struct RealtimeToolCallContext: Sendable, Hashable {
    /// The model's id for this call.
    public var callID: String
    /// The response that made the call, when known.
    public var responseID: String?
    /// Which tool chain the call belongs to. A chain starts with each
    /// response the runner didn't request (the user's turn) and goes on
    /// through the follow-ups the runner requests after tool results, so a
    /// larger number means the user has spoken since.
    public var chain: Int

    public init(callID: String, responseID: String? = nil, chain: Int) {
        self.callID = callID
        self.responseID = responseID
        self.chain = chain
    }

    /// The call being run, if any.
    @TaskLocal public static var current: RealtimeToolCallContext?
}
