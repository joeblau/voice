import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import os

/// A collection to open after creating it.
struct CollectionRoute: Identifiable, Hashable {
    let id: UUID
}

/// Settings → Knowledge → Collections (#65): lists of prompts to practice,
/// such as YC interview questions, each with an optional reference answer.
/// A collection is a `.collection` document; its prompts are its
/// `CollectionItem`s.
struct CollectionsListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(MemoryDocument.pages(of: .collection, byTitle: true))
    private var stored: [MemoryDocument]
    @State private var isCreating = false
    @State private var opened: CollectionRoute?
    @State private var failure: String?

    var body: some View {
        let collections = stored.uniqued()
        List {
            Section {
                Button("New Collection", systemImage: "plus.rectangle.on.rectangle") {
                    isCreating = true
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.newCollection)
            } footer: {
                Text("Paste a list of questions, one per line, to practice them with Grok.")
            }
            if collections.isEmpty {
                ContentUnavailableView(
                    "No Collections", systemImage: "list.bullet.rectangle",
                    description: Text("For example, the questions a YC partner asks in an interview."))
            } else {
                Section {
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collectionID: collection.id)
                        } label: {
                            CollectionRow(collection: collection)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { collections[$0].id }
                        Task { await delete(ids) }
                    }
                }
            }
        }
        .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionsList)
        .navigationTitle("Collections")
        .sheet(isPresented: $isCreating) {
            CollectionPasteSheet(mode: .create) { id in
                opened = CollectionRoute(id: id)
            }
        }
        .navigationDestination(item: $opened) { route in
            CollectionDetailView(collectionID: route.id)
        }
        .alert(
            "Couldn't Delete",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: {
            Text($0)
        }
    }

    private func delete(_ ids: [UUID]) async {
        do {
            for id in ids {
                try await environment.knowledgeBase.deleteDocument(id)
            }
        } catch {
            failure = String(localized: "The collection couldn't be deleted.")
        }
    }
}

private struct CollectionRow: View {
    let collection: MemoryDocument

    var body: some View {
        let items = collection.uniqueOrderedItems
        let practiced = items.filter { $0.practiceCount > 0 }.count
        VStack(alignment: .leading, spacing: 3) {
            Text(collection.title)
            Text(CollectionSummary.line(prompts: items.count, practiced: practiced))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one-line summaries of a collection. Pure, so unit tests cover them.
enum CollectionSummary {
    /// "30 questions", "30 questions · 4 practiced".
    static func line(prompts: Int, practiced: Int) -> String {
        let count = questions(prompts)
        guard practiced > 0 else { return count }
        return String(localized: "\(count) · \(practiced) practiced")
    }

    /// "1 question", "30 questions".
    static func questions(_ count: Int) -> String {
        count == 1 ? String(localized: "1 question") : String(localized: "\(count) questions")
    }

    /// "Practiced 3 times · 80%", or `nil` before the first practice.
    static func practice(count: Int, score: Double?) -> String? {
        guard count > 0 else { return nil }
        let times = count == 1 ? String(localized: "Practiced once") : String(localized: "Practiced \(count) times")
        guard let score else { return times }
        return "\(times) · \(score.formatted(.percent.precision(.fractionLength(0))))"
    }
}

/// One collection: its prompts in order, with their reference answers and
/// practice record. Prompts are edited one by one, reordered and deleted;
/// more are added by pasting.
struct CollectionDetailView: View {
    let collectionID: UUID
    @Environment(AppEnvironment.self) private var environment
    @Query private var copies: [MemoryDocument]
    /// The items, queried themselves (not through `copies`), so an edit to
    /// one item refreshes the list.
    @Query private var storedItems: [CollectionItem]
    @State private var isAdding = false
    @State private var editing: CollectionItemRoute?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var failure: String?

    init(collectionID: UUID) {
        self.collectionID = collectionID
        _copies = Query(filter: #Predicate<MemoryDocument> { $0.id == collectionID })
        _storedItems = Query(
            filter: #Predicate<CollectionItem> { $0.document?.id == collectionID },
            sort: [SortDescriptor(\.ordinal), SortDescriptor(\.createdAt)])
    }

    var body: some View {
        let collection = copies.first
        let items = Self.unique(storedItems)
        List {
            Section {
                Button("Add Questions…", systemImage: "text.badge.plus") { isAdding = true }
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.addQuestions)
            }
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        editing = CollectionItemRoute(id: item.id)
                    } label: {
                        CollectionItemRow(item: item, number: index + 1)
                    }
                    .foregroundStyle(.primary)
                }
                .onMove { source, destination in
                    var moved = items.map(\.id)
                    moved.move(fromOffsets: source, toOffset: destination)
                    let order = moved
                    perform { try await $0.reorderItems(in: collectionID, as: order) }
                }
                .onDelete { offsets in
                    let ids = offsets.map { items[$0].id }
                    perform { try await $0.deleteItems(ids) }
                }
            } header: {
                Text(
                    CollectionSummary.line(prompts: items.count, practiced: items.filter { $0.practiceCount > 0 }.count)
                )
            }
        }
        .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionItems)
        .navigationTitle(collection?.title ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()
                    .disabled(items.isEmpty)
                Button("Rename", systemImage: "pencil") {
                    newName = collection?.title ?? ""
                    isRenaming = true
                }
                .disabled(collection == nil)
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.renameCollection)
            }
        }
        .sheet(isPresented: $isAdding) {
            CollectionPasteSheet(mode: .add(collectionID: collectionID)) { _ in }
        }
        .sheet(item: $editing) { route in
            if let item = items.first(where: { $0.id == route.id }) {
                CollectionItemEditor(item: item)
            }
        }
        .alert("Rename Collection", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName
                let body = collection?.body ?? ""
                perform { _ = try await $0.saveDocument(collectionID, kind: .collection, title: name, body: body) }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Couldn't Change the Collection",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: {
            Text($0)
        }
        .overlay {
            if collection == nil {
                ContentUnavailableView("Collection Deleted", systemImage: "trash")
            }
        }
    }

    /// The items in order, one per id (CloudKit can mirror an item twice).
    static func unique(_ items: [CollectionItem]) -> [CollectionItem] {
        var seen = Set<UUID>()
        return items.sorted { ($0.ordinal, $0.createdAt) < ($1.ordinal, $1.createdAt) }
            .filter { seen.insert($0.id).inserted }
    }

    private func perform(_ edit: @escaping @Sendable (any KnowledgeBaseEditing) async throws -> Void) {
        let knowledgeBase = environment.knowledgeBase
        Task {
            do {
                try await edit(knowledgeBase)
            } catch {
                failure = KnowledgeBaseFailure.message(for: error)
            }
        }
    }
}

private struct CollectionItemRow: View {
    let item: CollectionItem
    let number: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.prompt)
                if let answer = item.referenceAnswer {
                    Text(answer)
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let practice = CollectionSummary.practice(count: item.practiceCount, score: item.score) {
                    Text(practice)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What to tell the user when a knowledge-base edit fails.
enum KnowledgeBaseFailure {
    static func message(for error: any Error) -> String {
        switch error {
        case KnowledgeBaseError.documentNotFound:
            String(localized: "This collection no longer exists.")
        case KnowledgeBaseError.itemNotFound:
            String(localized: "This question no longer exists.")
        case KnowledgeBaseError.emptyPrompt:
            String(localized: "A question can't be empty.")
        case KnowledgeBaseError.emptyTitle:
            String(localized: "A collection needs a name.")
        default:
            String(localized: "The change couldn't be saved.")
        }
    }
}

struct CollectionItemRoute: Identifiable, Hashable {
    let id: UUID
}

/// Edits one prompt and its reference answer.
private struct CollectionItemEditor: View {
    let item: CollectionItem
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: String
    @State private var answer: String
    @State private var failure: String?

    init(item: CollectionItem) {
        self.item = item
        _prompt = State(initialValue: item.prompt)
        _answer = State(initialValue: item.referenceAnswer ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Question", text: $prompt, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.itemPrompt)
                }
                Section {
                    TextField("Optional", text: $answer, axis: .vertical)
                        .lineLimit(4...)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.itemAnswer)
                } header: {
                    Text("Reference Answer")
                } footer: {
                    Text("When you practice, Grok compares your answer with this one.")
                }
                if let practice = CollectionSummary.practice(count: item.practiceCount, score: item.score) {
                    Section("Practice") {
                        Text(practice)
                        if let last = item.lastPracticedAt {
                            LabeledContent(
                                "Last Practiced", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Section {
                    Button("Delete Question", role: .destructive) {
                        let id = item.id
                        run { try await $0.deleteItems([id]) }
                    }
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.deleteItem)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = item.id
                        let prompt = prompt
                        let answer = answer
                        run { try await $0.updateItem(id, prompt: prompt, referenceAnswer: answer) }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.saveItem)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run(_ edit: @escaping @Sendable (any KnowledgeBaseEditing) async throws -> Void) {
        let knowledgeBase = environment.knowledgeBase
        Task {
            do {
                try await edit(knowledgeBase)
                dismiss()
            } catch {
                failure = KnowledgeBaseFailure.message(for: error)
            }
        }
    }
}

/// Creates a collection from pasted text, or adds pasted questions to one:
/// one question per line (see `CollectionImport` for the formats it
/// understands), with a live count of what will be added.
struct CollectionPasteSheet: View {
    enum Mode: Equatable {
        case create
        case add(collectionID: UUID)
    }

    let mode: Mode
    /// Called with the collection after it was created or added to.
    let onDone: (UUID) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var failure: String?

    private var parsed: CollectionImport { CollectionImport(parsing: text) }

    private var canSave: Bool {
        guard !isSaving else { return false }
        switch mode {
        case .create: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .add: return !parsed.items.isEmpty
        }
    }

    var body: some View {
        let parsed = parsed
        NavigationStack {
            Form {
                if mode == .create {
                    Section("Name") {
                        TextField("YC interview questions", text: $name)
                            .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionName)
                    }
                }
                Section {
                    TextField("What are you building?\nWho are your users?\n…", text: $text, axis: .vertical)
                        .lineLimit(6...12)
                        .font(.callout)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionPasteText)
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            paste(strings.joined(separator: "\n"))
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Spacer()
                        Button("Import File…", systemImage: "doc.badge.plus") { isImporting = true }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionImportFile)
                    }
                } header: {
                    Text("Questions")
                } footer: {
                    Text(
                        "One question per line; numbers and bullets are removed. Put a reference answer on the line "
                            + "after its question, starting with “A:”, or after a tab."
                    )
                }
                Section {
                    Text(preview(parsed))
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.collectionPreview)
                    ForEach(Array(parsed.items.prefix(3).enumerated()), id: \.offset) { index, item in
                        Text("\(index + 1). \(item.prompt)")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle(mode == .create ? "New Collection" : "Add Questions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Create" : "Add") {
                        Task { await save(parsed) }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.createCollection)
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: KnowledgeImportTypes.notes) { result in
                guard case .success(let url) = result else { return }
                if let file = KnowledgeImportTypes.read(url) {
                    paste(file.text)
                    if name.isEmpty, parsed.suggestedTitle == nil {
                        name = NoteImport(text: "x", fileName: file.name)?.title ?? ""
                    }
                } else {
                    failure = String(localized: "That file couldn't be read.")
                }
            }
        }
        .interactiveDismissDisabled(!text.isEmpty || !name.isEmpty)
    }

    private func preview(_ parsed: CollectionImport) -> String {
        let count = CollectionSummary.questions(parsed.items.count)
        guard parsed.duplicateCount > 0 else { return count }
        return String(localized: "\(count) · \(parsed.duplicateCount) repeats left out")
    }

    /// Adds pasted text to what is there, and takes a heading at its top as
    /// the name.
    private func paste(_ pasted: String) {
        text = text.isEmpty ? pasted : text + "\n" + pasted
        if mode == .create, name.trimmingCharacters(in: .whitespaces).isEmpty,
            let title = CollectionImport(parsing: pasted).suggestedTitle
        {
            name = title
        }
    }

    private func save(_ parsed: CollectionImport) async {
        isSaving = true
        defer { isSaving = false }
        let knowledgeBase = environment.knowledgeBase
        do {
            let collectionID: UUID
            switch mode {
            case .create:
                collectionID = UUID()
                _ = try await knowledgeBase.saveDocument(collectionID, kind: .collection, title: name, body: "")
            case .add(let id):
                collectionID = id
            }
            if !parsed.items.isEmpty {
                _ = try await knowledgeBase.addItems(parsed.items, to: collectionID)
            }
            dismiss()
            onDone(collectionID)
        } catch {
            Log.ui.error("Couldn't save a collection: \(String(describing: error), privacy: .public)")
            failure = KnowledgeBaseFailure.message(for: error)
        }
    }
}

#if DEBUG
    #Preview("Collections") {
        let environment = AppEnvironment.preview()
        NavigationStack {
            CollectionsListView()
        }
        .appEnvironment(environment)
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
