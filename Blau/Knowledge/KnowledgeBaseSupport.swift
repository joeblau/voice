import BlauPersistence
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Accessibility identifiers for the knowledge base screens (#65), shared
/// with UI tests.
enum KnowledgeBaseIdentifiers {
    static let aboutMe = "knowledge.aboutMe"
    static let company = "knowledge.company"
    static let notes = "knowledge.notes"
    static let collections = "knowledge.collections"

    static let saveStatus = "knowledge.saveStatus"

    static let profileName = "knowledge.aboutMe.name"
    static let profileText = "knowledge.aboutMe.text"
    static let profileSummary = "knowledge.aboutMe.summary"

    static let companyName = "knowledge.company.name"
    static func companyField(_ field: CompanyProfile.Field) -> String { "knowledge.company.\(field.rawValue)" }
    static let companyNotes = "knowledge.company.notes"

    static let notesList = "knowledge.notes.list"
    static let newNote = "knowledge.notes.new"
    static let importNotes = "knowledge.notes.import"
    static let noteTitle = "knowledge.note.title"
    static let noteBody = "knowledge.note.body"
    static let notePreviewToggle = "knowledge.note.preview"
    static let notePreview = "knowledge.note.previewText"
    static let deleteNote = "knowledge.note.delete"

    static let collectionsList = "knowledge.collections.list"
    static let newCollection = "knowledge.collections.new"
    static let collectionName = "knowledge.collection.name"
    static let collectionPasteText = "knowledge.collection.pasteText"
    static let collectionImportFile = "knowledge.collection.importFile"
    static let collectionPreview = "knowledge.collection.preview"
    static let createCollection = "knowledge.collection.create"
    static let collectionItems = "knowledge.collection.items"
    static let addQuestions = "knowledge.collection.addQuestions"
    static let renameCollection = "knowledge.collection.rename"
    static let itemPrompt = "knowledge.item.prompt"
    static let itemAnswer = "knowledge.item.answer"
    static let saveItem = "knowledge.item.save"
    static let deleteItem = "knowledge.item.delete"
}

// MARK: - Reading

extension Sequence where Element == MemoryDocument {
    /// One document per id, keeping the first of each in the sequence's
    /// order. CloudKit can mirror a record twice; the store writes every
    /// copy, so either shows the same text.
    func uniqued() -> [MemoryDocument] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension MemoryDocument {
    /// Every page of `kind`: most recently edited first, or by title.
    static func pages(of kind: DocumentKind, byTitle: Bool = false) -> FetchDescriptor<MemoryDocument> {
        let raw = kind.rawValue
        let order: [SortDescriptor<MemoryDocument>] =
            byTitle
            ? [SortDescriptor(\.title), SortDescriptor(\.id)]
            : [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)]
        return FetchDescriptor(predicate: #Predicate { $0.kindRaw == raw }, sortBy: order)
    }

    /// The collection's prompts in order, one per id.
    var uniqueOrderedItems: [CollectionItem] {
        var seen = Set<UUID>()
        return orderedCollectionItems.filter { seen.insert($0.id).inserted }
    }

    /// The first line of the body worth showing in a list.
    var excerpt: String {
        body.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*->_ ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// What to call a note with no title.
let untitledNoteTitle = String(localized: "Untitled Note")

// MARK: - Importing

enum KnowledgeImportTypes {
    /// `.txt` and `.md` files. `UTType.markdown` is iOS 27 only; the
    /// identifier works on iOS 26.
    static let notes: [UTType] = [
        .plainText, .text, UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText,
    ]

    /// Reads a file the user picked. `nil` when it is too large to be a
    /// note or unreadable.
    static func read(_ url: URL) -> (text: String, name: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= NoteImport.maximumFileSize,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return (NoteImport.decode(data), url.lastPathComponent)
    }
}

// MARK: - Editing

extension View {
    /// Keeps `draft` in step with the stored page while an editor is on
    /// screen: adopts edits synced from another device, and saves what is
    /// typed when the editor closes or the app leaves the foreground.
    func knowledgeDraft(_ draft: KnowledgeDraft, stored: MemoryDocument?) -> some View {
        modifier(KnowledgeDraftLifecycle(draft: draft, stored: stored))
    }
}

private struct KnowledgeDraftLifecycle: ViewModifier {
    let draft: KnowledgeDraft
    let stored: MemoryDocument?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: stored?.contentHash) {
                if let stored {
                    draft.adopt(title: stored.title, body: stored.body)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    Task { await draft.flush() }
                }
            }
            .onDisappear {
                Task { await draft.flush() }
            }
    }
}

/// "Saved", "Saving…" or why it couldn't, under an editor.
struct KnowledgeSaveStatus: View {
    let draft: KnowledgeDraft

    var body: some View {
        Group {
            if draft.failure != nil {
                Label(
                    "Couldn't save. Your text is kept; keep typing to try again.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            } else if draft.isSaving || draft.hasUnsavedChanges {
                Text("Saving…")
            } else if !(draft.title.isEmpty && draft.body.isEmpty) {
                Text("Saved. Syncs to your devices through iCloud.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(KnowledgeBaseIdentifiers.saveStatus)
    }
}

/// A Markdown body rendered for reading: headings, bullet and numbered
/// lists, block quotes, code blocks, and inline styles and links in
/// paragraphs. Not a full CommonMark renderer; the text itself is what
/// Blau searches.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(marker: String, text: String)
        case quote(String)
        case code(String)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Self.inline(text)
        case .bullet(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit()
                Self.inline(text)
            }
        case .quote(let text):
            Self.inline(text)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .code(let text):
            Text(text)
                .font(.callout.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6))
        }
    }

    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }

    /// Splits `markdown` into blocks. Pure, so unit tests cover it.
    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if let bullet = bullet(trimmed) {
                flushParagraph()
                blocks.append(bullet)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let code {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// `# Title` to `###### Title`.
    private static func heading(_ line: String) -> Block? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func bullet(_ line: String) -> Block? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return .bullet(marker: "•", text: String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")",
            rest.dropFirst().first == " "
        else { return nil }
        return .bullet(marker: "\(digits).", text: String(rest.dropFirst(2)))
    }
}
