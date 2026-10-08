import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func makeContext() throws -> ModelContext {
    ModelContext(try BlauModelContainer.makeInMemory())
}

/// Onboarding's "Tell Blau about you" step (#44): the profile document it
/// writes into the knowledge base.
@Suite("About you document")
struct AboutYouDocumentTests {
    @Test func savingCreatesAProfileDocument() throws {
        let context = try makeContext()
        #expect(try AboutYouDocument.text(in: context) == nil)
        #expect(try AboutYouDocument.onboardingRequirement(in: context) == .missing)

        let saved = try #require(
            try AboutYouDocument.save("  I'm Joe. I'm building Blau, a voice app.\n", in: context, at: t0))
        #expect(saved.kind == .profile)
        #expect(saved.title == AboutYouDocument.title)
        #expect(saved.body == "I'm Joe. I'm building Blau, a voice app.")
        #expect(saved.createdAt == t0)
        #expect(saved.isContentHashCurrent)

        // Saved, so another context (the indexer's) sees it.
        let other = ModelContext(context.container)
        #expect(try AboutYouDocument.text(in: other) == "I'm Joe. I'm building Blau, a voice app.")
        #expect(try AboutYouDocument.onboardingRequirement(in: other) == .satisfied)
    }

    @Test func savingAgainUpdatesTheSameDocument() throws {
        let context = try makeContext()
        let first = try #require(try AboutYouDocument.save("First", in: context, at: t0))
        let later = t0.addingTimeInterval(60)
        let second = try #require(try AboutYouDocument.save("Second", in: context, at: later))
        #expect(first.id == second.id)
        #expect(try context.fetchCount(FetchDescriptor<MemoryDocument>()) == 1)
        #expect(second.body == "Second")
        #expect(second.updatedAt == later)
        #expect(second.contentHash == MemoryDocument.contentHash(title: AboutYouDocument.title, body: "Second"))
    }

    @Test func emptyTextChangesNothing() throws {
        let context = try makeContext()
        #expect(try AboutYouDocument.save(" \n\t", in: context, at: t0) == nil)
        #expect(try context.fetchCount(FetchDescriptor<MemoryDocument>()) == 0)

        try AboutYouDocument.save("Kept", in: context, at: t0)
        #expect(try AboutYouDocument.save("", in: context, at: t0.addingTimeInterval(1)) == nil)
        #expect(try AboutYouDocument.text(in: context) == "Kept")
    }

    @Test func readsTheNewestProfileAndIgnoresOtherKinds() throws {
        // Two devices each wrote one before they synced.
        let context = try makeContext()
        context.insert(MemoryDocument(kind: .note, title: "Note", body: "Not a profile", createdAt: t0))
        context.insert(MemoryDocument(kind: .profile, title: "About me", body: "Older", createdAt: t0))
        let newer = MemoryDocument(
            kind: .profile, title: "About me", body: "Newer", createdAt: t0, updatedAt: t0.addingTimeInterval(10))
        context.insert(newer)
        try context.save()

        #expect(try AboutYouDocument.text(in: context) == "Newer")
        let updated = try #require(try AboutYouDocument.save("Newest", in: context, at: t0.addingTimeInterval(20)))
        #expect(updated.id == newer.id)
    }

    @Test func anEmptyProfileDocumentDoesNotCount() throws {
        let context = try makeContext()
        context.insert(MemoryDocument(kind: .profile, title: "About me", body: "   ", createdAt: t0))
        try context.save()
        #expect(try AboutYouDocument.text(in: context) == nil)
        #expect(try AboutYouDocument.onboardingRequirement(in: context) == .missing)
    }
}

/// Onboarding's iCloud step (#44).
@Suite("Sync state onboarding")
struct SyncStateOnboardingTests {
    @Test func onlyRunningSyncIsDone() {
        #expect(SyncState.checking.onboardingRequirement == .unknown)
        #expect(SyncState.syncing(lastSync: nil).onboardingRequirement == .satisfied)
        #expect(SyncState.upToDate(lastSync: t0).onboardingRequirement == .satisfied)
        #expect(
            SyncState.failing(CloudSyncError(domain: "Blau", code: 0, message: "x"), lastSync: nil)
                .onboardingRequirement == .missing)
        #expect(SyncState.off(.signedOut).onboardingRequirement == .missing)
        #expect(SyncState.off(.notAvailableInThisBuild).onboardingRequirement == .missing)
        #expect(SyncState.notSaved(storeFailed: false).onboardingRequirement == .missing)
    }
}
