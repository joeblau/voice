/// What a knowledge-base `Document` is. Persisted as `Document.kindRaw`.
public enum DocumentKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// A free-form note.
    case note
    /// What the user's company does: product, market, traction, team.
    case company
    /// The user's own background, written or edited by the user. (The
    /// model-maintained summary is `ProfileBlock`.)
    case profile
    /// A list of prompts to practice, held in `Document.collectionItems`
    /// (e.g. YC interview questions).
    case collection
}

/// What a `MemoryEntity` is. Persisted as `MemoryEntity.typeRaw`.
public enum MemoryEntityType: String, CaseIterable, Codable, Hashable, Sendable {
    case person
    /// A company, investor, school, team...
    case organization
    case place
    /// Something someone makes or sells.
    case product
    /// Something the user is working on.
    case project
    /// A dated occurrence: a meeting, a launch, a trip.
    case event
    /// An idea or subject that isn't any of the above.
    case concept
    /// The extractor couldn't tell.
    case other
}

/// Where a `Fact` came from. Persisted as `Fact.originRaw`.
public enum FactOrigin: String, CaseIterable, Codable, Hashable, Sendable {
    /// Inferred by a model from a conversation, e.g. by the post-conversation
    /// extraction pipeline (#66).
    case extracted
    /// Entered, confirmed or explicitly asked to be remembered by the user,
    /// so it outranks an extracted fact that contradicts it.
    case user
}
