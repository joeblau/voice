import BlauCore
import Foundation
import Observation

/// The text of one knowledge-base page while it is being edited (#65), saved
/// as the user types.
///
/// Every change schedules a save `delay` after the last keystroke, so a
/// burst of typing is one write (one CloudKit export, one re-index) rather
/// than one per character. `flush()` saves at once: call it when the editor
/// closes or the app leaves the foreground.
///
/// When the stored page changes underneath (an edit synced from another
/// device), `adopt(title:body:)` takes the new text, unless the user has
/// typed something that isn't saved yet: then their text wins and is saved
/// over it, the same last-writer-wins CloudKit applies to the record.
@MainActor
@Observable
public final class KnowledgeDraft {
    public let kind: DocumentKind
    /// The page being edited. Can change after the first save: see
    /// `KnowledgeBaseStore.saveDocument` for the profile and company pages.
    public private(set) var documentID: UUID

    public var title: String {
        didSet { if title != oldValue { textChanged() } }
    }

    public var body: String {
        didSet { if body != oldValue { textChanged() } }
    }

    /// Bumped whenever `adopt` replaces the text, so views that keep their
    /// own copy of it (the company page's fields) know to re-read.
    public private(set) var revision = 0

    /// The last save's error, cleared by the next successful save.
    public private(set) var failure: (any Error)?

    /// Whether a save is in flight.
    public private(set) var isSaving = false

    /// The content hash of the text the store holds, as far as this draft
    /// knows.
    @ObservationIgnored private var savedHash: String
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var isDiscarded = false
    @ObservationIgnored private let editor: any KnowledgeBaseEditing
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private let delay: Duration

    /// How long after the last change a save starts.
    public static let defaultDelay: Duration = .seconds(1)

    /// - Parameters:
    ///   - documentID: The page to edit, or a new id for a page that doesn't
    ///     exist yet (it is created by the first save with any text).
    ///   - title, body: The stored text, empty for a new page.
    public init(
        kind: DocumentKind, documentID: UUID, title: String = "", body: String = "",
        editor: any KnowledgeBaseEditing, clock: any BlauClock = SystemClock(), delay: Duration = defaultDelay
    ) {
        self.kind = kind
        self.documentID = documentID
        self.title = title
        self.body = body
        self.editor = editor
        self.clock = clock
        self.delay = delay
        self.savedHash = MemoryDocument.contentHash(title: title, body: body)
    }

    /// Whether the text differs from what was last saved or loaded.
    public var hasUnsavedChanges: Bool {
        MemoryDocument.contentHash(title: title, body: body) != savedHash
    }

    /// The stored page changed (for example from another device): take its
    /// text unless there are unsaved edits. Text this draft saved itself is
    /// recognized and ignored.
    public func adopt(title newTitle: String, body newBody: String) {
        let hash = MemoryDocument.contentHash(title: newTitle, body: newBody)
        guard hash != savedHash else { return }
        guard !hasUnsavedChanges else { return }
        adopting = true
        title = newTitle
        body = newBody
        adopting = false
        savedHash = hash
        revision += 1
    }

    /// Saves now, if there is anything to save.
    public func flush() async {
        pending?.cancel()
        pending = nil
        await save()
    }

    /// Stops saving for good: the page was deleted, and a pending save
    /// must not bring it back.
    public func discard() {
        isDiscarded = true
        pending?.cancel()
        pending = nil
    }

    /// Waits for the save scheduled by the last change, for tests.
    func waitForPendingSave() async {
        await pending?.value
    }

    private func textChanged() {
        guard !adopting, !isDiscarded else { return }
        pending?.cancel()
        let clock = clock
        let delay = delay
        pending = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.save()
        }
    }

    private func save() async {
        guard !isDiscarded, hasUnsavedChanges else { return }
        let title = title
        let body = body
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await editor.saveDocument(documentID, kind: kind, title: title, body: body)
            documentID = result.id
            savedHash = MemoryDocument.contentHash(title: title, body: body)
            failure = nil
        } catch {
            failure = error
        }
    }
}
