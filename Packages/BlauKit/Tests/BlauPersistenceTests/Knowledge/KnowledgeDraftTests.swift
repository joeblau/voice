import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauPersistence

@MainActor
@Suite("Knowledge draft autosave")
struct KnowledgeDraftTests {
    /// Records saves; can be told to fail, and to answer with another id.
    final class RecordingEditor: KnowledgeBaseEditing {
        struct Save: Equatable {
            var id: UUID
            var title: String
            var body: String
        }

        let saves = Mutex<[Save]>([])
        let failure = Mutex<(any Error)?>(nil)
        let redirect = Mutex<UUID?>(nil)

        var recorded: [Save] { saves.withLock { $0 } }

        func saveDocument(_ id: UUID, kind: DocumentKind, title: String, body: String) async throws
            -> KnowledgeDocumentSave
        {
            if let error = failure.withLock({ $0 }) { throw error }
            saves.withLock { $0.append(Save(id: id, title: title, body: body)) }
            return KnowledgeDocumentSave(id: redirect.withLock { $0 } ?? id, changed: true)
        }

        func deleteDocument(_ id: UUID) async throws {}
        func addItems(_ items: [CollectionImport.Item], to collectionID: UUID) async throws -> CollectionAddResult {
            CollectionAddResult()
        }
        func updateItem(_ id: UUID, prompt: String, referenceAnswer: String?) async throws {}
        func deleteItems(_ ids: [UUID]) async throws {}
        func reorderItems(in collectionID: UUID, as order: [UUID]) async throws {}
    }

    struct Failure: Error {}

    let clock = ManualClock()
    let editor = RecordingEditor()
    let id = UUID()

    func draft(title: String = "", body: String = "") -> KnowledgeDraft {
        KnowledgeDraft(kind: .note, documentID: id, title: title, body: body, editor: editor, clock: clock)
    }

    /// Lets the scheduled save's timer elapse and waits for the save.
    func elapse(_ draft: KnowledgeDraft) async {
        await clock.waitForSleepers()
        clock.advance(by: KnowledgeDraft.defaultDelay)
        await draft.waitForPendingSave()
    }

    @Test func aBurstOfTypingIsOneSaveAfterThePause() async {
        let draft = draft()
        #expect(!draft.hasUnsavedChanges)
        for prefix in ["P", "Pr", "Pri", "Pricing"] {
            draft.title = prefix
        }
        draft.body = "Two tiers."
        #expect(draft.hasUnsavedChanges)
        #expect(editor.recorded.isEmpty)

        await elapse(draft)
        #expect(editor.recorded == [.init(id: id, title: "Pricing", body: "Two tiers.")])
        #expect(!draft.hasUnsavedChanges)
        #expect(draft.failure == nil)
    }

    @Test func flushSavesAtOnceAndOnlyWhenSomethingChanged() async {
        let draft = draft(title: "Pricing", body: "Two tiers.")
        await draft.flush()
        #expect(editor.recorded.isEmpty)

        draft.body = "Three tiers."
        await draft.flush()
        #expect(editor.recorded.map(\.body) == ["Three tiers."])
        // The cancelled timer doesn't save again.
        clock.advance(by: .seconds(5))
        await draft.waitForPendingSave()
        #expect(editor.recorded.count == 1)
    }

    @Test func aStoredChangeIsAdoptedWhenNothingIsUnsaved() async {
        let draft = draft(title: "Pricing", body: "Two tiers.")
        draft.adopt(title: "Pricing", body: "Synced from the iPad.")
        #expect(draft.body == "Synced from the iPad.")
        #expect(draft.revision == 1)
        #expect(!draft.hasUnsavedChanges)
        // Adopting isn't an edit: nothing is saved back.
        await draft.flush()
        #expect(editor.recorded.isEmpty)
    }

    @Test func unsavedTypingWinsOverAStoredChange() async {
        let draft = draft(title: "Pricing", body: "Two tiers.")
        draft.body = "Typed here."
        draft.adopt(title: "Pricing", body: "Synced from the iPad.")
        #expect(draft.body == "Typed here.")
        #expect(draft.revision == 0)
        await elapse(draft)
        #expect(editor.recorded.map(\.body) == ["Typed here."])
    }

    @Test func theDraftsOwnSaveComingBackIsIgnored() async {
        let draft = draft()
        draft.title = "Pricing"
        await draft.flush()
        draft.adopt(title: "Pricing", body: "")
        #expect(draft.revision == 0)
    }

    @Test func aFailedSaveIsReportedAndRetriedByTheNextChange() async {
        let draft = draft()
        editor.failure.withLock { $0 = Failure() }
        draft.title = "Pricing"
        await draft.flush()
        #expect(draft.failure is Failure)
        #expect(draft.hasUnsavedChanges)

        editor.failure.withLock { $0 = nil }
        draft.body = "Two tiers."
        await elapse(draft)
        #expect(draft.failure == nil)
        #expect(editor.recorded == [.init(id: id, title: "Pricing", body: "Two tiers.")])
    }

    @Test func aDiscardedDraftNeverSaves() async {
        let draft = draft()
        draft.title = "Pricing"
        draft.discard()
        await draft.flush()
        draft.body = "More"
        clock.advance(by: .seconds(5))
        await draft.waitForPendingSave()
        #expect(editor.recorded.isEmpty)
    }

    @Test func theStoreCanRedirectASingletonPage() async {
        let existing = UUID()
        editor.redirect.withLock { $0 = existing }
        let draft = KnowledgeDraft(kind: .company, documentID: id, editor: editor, clock: clock)
        draft.title = "Larderly"
        await draft.flush()
        #expect(draft.documentID == existing)
        draft.body = "## Product\nApp"
        await draft.flush()
        #expect(editor.recorded.last?.id == existing)
    }
}
