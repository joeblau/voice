import BlauCore
import Foundation
import SwiftData

/// The user's own description of themselves, written in onboarding's
/// "Tell Blau about you" step (#44) and kept as the knowledge base's
/// `.profile` document (`DocumentKind.profile`).
///
/// It is an ordinary `Document`, so it syncs through iCloud. From the first
/// conversation on, Grok gets it two ways: `ProfileComposer` pins every
/// `.profile` document verbatim into the session instructions ("In the
/// user's own words", #67), and the memory indexer (#63) chunks and embeds
/// it like any other page, so `search_memory` finds it too. (The
/// model-maintained summary is `ProfileBlock`, which consolidation, #67,
/// keeps from what Blau learns.) Settings → Knowledge → About Me (#65)
/// edits the same kind of document.
///
/// Two devices can each write one before they sync (`kind` isn't unique in
/// CloudKit), so reads take the most recently updated one, ties broken by
/// `id` so every device picks the same, and saving updates that one.
public enum AboutYouDocument {
    /// The title a new profile document gets.
    public static let title = "About me"

    /// Fetches the most recently updated `.profile` document.
    public static func latest() -> FetchDescriptor<MemoryDocument> {
        let kind = DocumentKind.profile.rawValue
        var descriptor = FetchDescriptor<MemoryDocument>(
            predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// The profile text, or `nil` when there is none (or only an empty one).
    public static func text(in context: ModelContext) throws -> String? {
        guard let body = try context.fetch(latest()).first?.body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : body
    }

    /// Onboarding's "about you" step: done once there is a non-empty
    /// profile document (perhaps written on another device).
    public static func onboardingRequirement(in context: ModelContext) throws -> OnboardingRequirement {
        try text(in: context) == nil ? .missing : .satisfied
    }

    /// Saves `text` as the profile: updates the latest profile document, or
    /// inserts one titled ``title``, then saves the context. Surrounding
    /// whitespace is trimmed; empty text changes nothing.
    ///
    /// - Returns: The document, or `nil` when `text` was empty.
    @discardableResult
    public static func save(_ text: String, in context: ModelContext, at date: Date = Date()) throws
        -> MemoryDocument?
    {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let document: MemoryDocument
        if let existing = try context.fetch(latest()).first {
            existing.update(body: body, at: date)
            document = existing
        } else {
            document = MemoryDocument(kind: .profile, title: title, body: body, createdAt: date)
            context.insert(document)
        }
        try context.save()
        return document
    }
}
