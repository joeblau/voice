import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import os

/// A note to open in the editor: an existing one, or a new one that is
/// created by its first save.
struct NoteRoute: Identifiable, Hashable {
    let id: UUID
}

/// Settings → Knowledge → Notes (#65): Markdown documents the user wrote,
/// pasted or imported from `.txt` / `.md` files. Newest edit first.
struct NotesListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(MemoryDocument.pages(of: .note))
    private var stored: [MemoryDocument]
    @State private var opened: NoteRoute?
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        let notes = stored.uniqued()
        List {
            Section {
                Button("New Note", systemImage: "square.and.pencil") {
                    opened = NoteRoute(id: UUID())
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.newNote)
                Button("Import Files…", systemImage: "doc.badge.plus") {
                    isImporting = true
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.importNotes)
                HStack {
                    Text("Paste text as a new note")
                        .foregroundStyle(.secondary)
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        Task { await create(from: strings.joined(separator: "\n\n"), fileName: nil) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                }
            } footer: {
                Text("Grok looks things up in your notes when it helps answer you. Markdown is fine.")
            }

            if notes.isEmpty {
                ContentUnavailableView(
                    "No Notes", systemImage: "note.text",
                    description: Text("Write, paste or import what you'd like Blau to know."))
            } else {
                Section {
                    ForEach(notes) { note in
                        NavigationLink {
                            NoteEditorView(documentID: note.id)
                        } label: {
                            NoteRow(note: note)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { notes[$0].id }
                        Task { await delete(ids) }
                    }
                }
            }
        }
        .accessibilityIdentifier(KnowledgeBaseIdentifiers.notesList)
        .navigationTitle("Notes")
        .navigationDestination(item: $opened) { route in
            NoteEditorView(documentID: route.id)
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: KnowledgeImportTypes.notes, allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .alert(
            "Notes",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            presenting: message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @discardableResult
    private func create(from text: String, fileName: String?) async -> UUID? {
        guard let note = NoteImport(text: text, fileName: fileName) else { return nil }
        let id = UUID()
        do {
            _ = try await environment.knowledgeBase.saveDocument(id, kind: .note, title: note.title, body: note.body)
            return id
        } catch {
            Log.ui.error("Couldn't create a note: \(String(describing: error), privacy: .public)")
            message = String(localized: "The note couldn't be saved.")
            return nil
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result else { return }
        var created: [UUID] = []
        var skipped: [String] = []
        for url in urls {
            guard let file = KnowledgeImportTypes.read(url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            if let id = await create(from: file.text, fileName: file.name) {
                created.append(id)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            message = String(
                localized: "Couldn't import \(skipped.joined(separator: ", ")): empty, unreadable or larger than 2 MB.")
        } else if created.count == 1, let id = created.first {
            opened = NoteRoute(id: id)
        }
    }

    private func delete(_ ids: [UUID]) async {
        do {
            for id in ids {
                try await environment.knowledgeBase.deleteDocument(id)
            }
        } catch {
            message = String(localized: "The note couldn't be deleted.")
        }
    }
}

private struct NoteRow: View {
    let note: MemoryDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? untitledNoteTitle : note.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
                if !note.excerpt.isEmpty {
                    Text(note.excerpt).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One note: its title and Markdown body, saved as the user types, with a
/// rendered preview.
struct NoteEditorView: View {
    let documentID: UUID
    @Environment(AppEnvironment.self) private var environment
    @Query private var copies: [MemoryDocument]

    init(documentID: UUID) {
        self.documentID = documentID
        _copies = Query(filter: #Predicate<MemoryDocument> { $0.id == documentID })
    }

    var body: some View {
        let stored = copies.first
        NoteEditor(
            draft: KnowledgeDraft(
                kind: .note, documentID: documentID, title: stored?.title ?? "", body: stored?.body ?? "",
                editor: environment.knowledgeBase, clock: environment.clock),
            stored: stored)
    }
}

private struct NoteEditor: View {
    @State var draft: KnowledgeDraft
    let stored: MemoryDocument?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var isPreviewing = false
    @State private var isConfirmingDelete = false
    @FocusState private var focus: Field?

    enum Field { case title, body }

    var body: some View {
        @Bindable var draft = draft
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .font(.title2.bold())
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.noteTitle)
                if isPreviewing {
                    MarkdownPreview(markdown: draft.body)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.notePreview)
                } else {
                    TextField("Write in Markdown…", text: $draft.body, axis: .vertical)
                        .focused($focus, equals: .body)
                        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.noteBody)
                }
                KnowledgeSaveStatus(draft: draft)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(draft.title.isEmpty ? untitledNoteTitle : draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In the navigation bar, so they stay reachable while the
            // keyboard is up.
            ToolbarItemGroup(placement: .primaryAction) {
                Button(isPreviewing ? "Edit" : "Preview", systemImage: isPreviewing ? "pencil" : "eye") {
                    focus = nil
                    isPreviewing.toggle()
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.notePreviewToggle)
                Menu("More", systemImage: "ellipsis") {
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(draft.title.isEmpty && draft.body.isEmpty)
                    Button("Delete Note", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .disabled(stored == nil)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.deleteNote)
                }
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("It is removed from Blau's memory on all your devices.")
        }
        .onAppear {
            if stored == nil { focus = .title }
        }
        .onDisappear {
            // Typed nothing (or cleared everything): don't keep an empty note.
            let isBlank =
                draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank, stored != nil {
                draft.discard()
                let knowledgeBase = environment.knowledgeBase
                let id = draft.documentID
                Task { try? await knowledgeBase.deleteDocument(id) }
            }
        }
        .knowledgeDraft(draft, stored: stored)
    }

    private var shareText: String {
        draft.title.isEmpty ? draft.body : "# \(draft.title)\n\n\(draft.body)"
    }

    private func delete() async {
        let id = draft.documentID
        draft.discard()
        do {
            try await environment.knowledgeBase.deleteDocument(id)
            dismiss()
        } catch {
            Log.ui.error("Couldn't delete a note: \(String(describing: error), privacy: .public)")
        }
    }
}

#if DEBUG
    #Preview("Notes") {
        let environment = AppEnvironment.preview()
        NavigationStack {
            NotesListView()
        }
        .appEnvironment(environment)
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
