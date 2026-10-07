import BlauPersistence
import Foundation

/// Cuts SwiftData snapshots into index chunks (#62).
///
/// - **Conversations:** one exchange per chunk (the user's turn and Blau's
///   reply, the unit LongMemEval recommends), with the previous exchange as
///   overlap. The key text is prefixed with the date, the topic and the
///   facts extracted from the exchange (LongMemEval's fact-augmented keys):
///   `[March 14, 2026] [Fundraising] facts: Acme raised a $2M seed round`.
/// - **Documents:** split at headings and paragraphs, each chunk prefixed
///   with the document title and the heading it sits under.
/// - **Collection items:** one chunk each, prefixed with the collection's
///   title.
/// - **Facts:** one chunk each, prefixed with the date they became true.
///
/// Chunking is deterministic: the same snapshot always gives the same
/// chunks, ids and hashes, so a rebuild keeps every vector whose key text
/// didn't change. Key texts stay within `policy.maximumTokens` (as counted
/// by `tokenCounter`): longer exchanges and paragraphs are split at
/// sentences, and the overlap and facts are trimmed first. Collection items
/// are the exception: one chunk each, however long.
public struct MemoryChunker: Sendable {
    public var policy: ChunkingPolicy
    public var tokenCounter: any ChunkTokenCounting

    public init(policy: ChunkingPolicy = .default, tokenCounter: any ChunkTokenCounting = ApproximateTokenCounter()) {
        self.policy = policy
        self.tokenCounter = tokenCounter
    }

    // MARK: - Conversations

    /// One finalized exchange: everything the user said up to Blau's reply,
    /// plus that reply (the grouping `BlauTopics.ExchangeAssembler` uses).
    public struct Exchange: Hashable, Sendable {
        public var utteranceIDs: [UUID]
        public var userText: String
        public var agentText: String
        public var startedAt: Date
        public var topicID: UUID?

        /// `User: …` and `Blau: …` lines, the format of #59's eval set.
        public var text: String {
            var lines: [String] = []
            if !userText.isEmpty { lines.append("User: " + userText) }
            if !agentText.isEmpty { lines.append("Blau: " + agentText) }
            return lines.joined(separator: "\n")
        }
    }

    /// The conversation's exchanges, in the order they were spoken. System
    /// utterances, unknown roles and blank text are skipped. A user
    /// utterance after Blau has spoken starts the next exchange.
    public static func exchanges(in conversation: ConversationSnapshot) -> [Exchange] {
        let spoken = conversation.utterances
            .filter { $0.role == .user || $0.role == .agent }
            .filter { $0.text.contains { !$0.isWhitespace } }
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }

        var exchanges: [Exchange] = []
        var pending: [ConversationSnapshot.UtteranceSnapshot] = []
        func close() {
            guard let first = pending.first else { return }
            func text(_ role: UtteranceRole) -> String {
                pending.filter { $0.role == role }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
            }
            let topicID =
                pending.first { $0.role == .user && $0.topicID != nil }?.topicID
                ?? pending.first { $0.topicID != nil }?.topicID
            exchanges.append(
                Exchange(
                    utteranceIDs: pending.map(\.id), userText: text(.user), agentText: text(.agent),
                    startedAt: first.startedAt, topicID: topicID))
            pending.removeAll()
        }
        for utterance in spoken {
            if utterance.role == .user, pending.contains(where: { $0.role == .agent }) { close() }
            pending.append(utterance)
        }
        close()
        return exchanges
    }

    /// The conversation's chunks: one per exchange (more for an exchange too
    /// long for one), numbered from 0.
    ///
    /// - Parameter factsByUtterance: Fact statements by the utterance they
    ///   were extracted from (`FactSnapshot.sourceUtteranceID`); they go in
    ///   the `facts:` part of the exchange's key text.
    public func chunks(for conversation: ConversationSnapshot, factsByUtterance: [UUID: [String]] = [:])
        -> [MemoryChunk]
    {
        let topicTitles = Dictionary(
            conversation.topics.compactMap { topic in topic.title.map { (topic.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        var chunks: [MemoryChunk] = []
        var previousText: String?
        for exchange in Self.exchanges(in: conversation) {
            var facts: [String] = []
            for id in exchange.utteranceIDs {
                for statement in factsByUtterance[id] ?? [] {
                    let trimmed = Self.singleLine(statement)
                    if !trimmed.isEmpty, !facts.contains(trimmed) { facts.append(trimmed) }
                }
            }
            let prefix = exchangePrefix(
                date: exchange.startedAt, topic: exchange.topicID.flatMap { topicTitles[$0] }, facts: facts)
            let pieces = splitter(prefix: prefix).split(exchange.text)
            for (index, piece) in pieces.enumerated() {
                let context = index == 0 ? previousText : pieces[index - 1]
                chunks.append(
                    MemoryChunk(
                        sourceID: conversation.id, sourceKind: .conversation, ordinal: chunks.count, text: piece,
                        keyText: keyText(prefix: prefix, body: piece, context: context),
                        createdAt: exchange.startedAt, topicID: exchange.topicID, conversationID: conversation.id))
            }
            previousText = exchange.text
        }
        return chunks
    }

    /// `[date] [topic] facts: a; b`, with as many facts as fit in half the
    /// budget.
    func exchangePrefix(date: Date, topic: String?, facts: [String]) -> String {
        var prefix = "[\(formatted(date))]"
        if let topic = topic.map(Self.singleLine), !topic.isEmpty { prefix += " [\(topic)]" }
        var included: [String] = []
        for fact in facts.prefix(policy.maximumFactsPerExchange) {
            let candidate = prefix + " facts: " + (included + [fact]).joined(separator: "; ")
            guard tokenCounter.tokenCount(candidate) <= policy.maximumTokens / 2 else { break }
            included.append(fact)
        }
        if !included.isEmpty { prefix += " facts: " + included.joined(separator: "; ") }
        return prefix
    }

    // MARK: - Documents

    /// The document's chunks, split at headings and paragraphs: a chunk
    /// ends at a heading once it holds `policy.minimumDocumentTokens`, or
    /// when the next paragraph doesn't fit. A document with no body is one
    /// chunk holding its title. Collection items are chunked separately
    /// (`chunk(for:in:)`).
    public func chunks(for document: DocumentSnapshot) -> [MemoryChunk] {
        let title = Self.singleLine(document.title)
        let blocks = Self.blocks(in: document.body)
        func chunk(_ ordinal: Int, text: String, path: [String]) -> MemoryChunk {
            MemoryChunk(
                sourceID: document.id, sourceKind: .document, ordinal: ordinal, text: text,
                keyText: Self.joined(documentPrefix(title: title, path: path), text), createdAt: document.updatedAt)
        }
        guard !blocks.isEmpty else {
            guard !title.isEmpty else { return [] }
            return [
                MemoryChunk(
                    sourceID: document.id, sourceKind: .document, ordinal: 0, text: title, keyText: title,
                    createdAt: document.updatedAt)
            ]
        }

        var chunks: [MemoryChunk] = []
        var current: (path: [String], text: String)?
        func flush() {
            if let current { chunks.append(chunk(chunks.count, text: current.text, path: current.path)) }
            current = nil
        }
        for block in blocks {
            if var open = current {
                let prefix = documentPrefix(title: title, path: open.path)
                let isLongEnough =
                    tokenCounter.tokenCount(Self.joined(prefix, open.text)) >= policy.minimumDocumentTokens
                let candidate = open.text + "\n\n" + block.text
                if !(block.startsSection && isLongEnough) && fits(Self.joined(prefix, candidate)) {
                    open.text = candidate
                    current = open
                    continue
                }
                flush()
            }
            let prefix = documentPrefix(title: title, path: block.path)
            let pieces = splitter(prefix: prefix).split(block.text)
            for piece in pieces.dropLast() {
                chunks.append(chunk(chunks.count, text: piece, path: block.path))
            }
            if let last = pieces.last { current = (block.path, last) }
        }
        flush()
        return chunks
    }

    /// `[Title] [Heading › Subheading]`.
    func documentPrefix(title: String, path: [String]) -> String {
        var prefix = title.isEmpty ? "" : "[\(title)]"
        if !path.isEmpty {
            prefix += (prefix.isEmpty ? "" : " ") + "[\(path.joined(separator: " › "))]"
        }
        return prefix
    }

    /// A paragraph of a document, with the headings above it.
    struct Block: Hashable {
        /// The headings the paragraph sits under, outermost first.
        var path: [String]
        /// The paragraph, preceded by any headings that start right above
        /// it (as Markdown), so a merged chunk keeps them.
        var text: String
        /// Whether a heading starts right above the paragraph.
        var startsSection: Bool
    }

    /// Markdown paragraphs (separated by blank lines) with their heading
    /// paths. ATX headings (`#` to `######`) set the path; a heading with
    /// no paragraph under it is kept as a paragraph of its own.
    static func blocks(in body: String) -> [Block] {
        var blocks: [Block] = []
        var path: [(level: Int, title: String)] = []
        var pendingHeadings: [String] = []
        var pendingPath: [String]?
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty || !pendingHeadings.isEmpty else { return }
            let text = (pendingHeadings + (paragraph.isEmpty ? [] : [paragraph.joined(separator: "\n")]))
                .joined(separator: "\n")
            blocks.append(
                Block(path: pendingPath ?? path.map(\.title), text: text, startsSection: !pendingHeadings.isEmpty))
            paragraph.removeAll()
            pendingHeadings.removeAll()
            pendingPath = nil
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !paragraph.isEmpty { flushParagraph() }
                continue
            }
            if let heading = heading(in: line) {
                if !paragraph.isEmpty { flushParagraph() }
                path.removeAll { $0.level >= heading.level }
                path.append(heading)
                pendingHeadings.append(line)
                pendingPath = path.map(\.title)
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    /// The level and text of an ATX heading line, or `nil`.
    static func heading(in line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces).replacing(/\s+#+$/, with: "")
        guard !title.isEmpty else { return nil }
        return (hashes, singleLine(title))
    }

    // MARK: - Collection items and facts

    /// One chunk for a collection item: the prompt and its reference answer,
    /// keyed with the collection's title. `nil` for a blank prompt.
    public func chunk(for item: DocumentSnapshot.ItemSnapshot, in collection: DocumentSnapshot) -> MemoryChunk? {
        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        var text = prompt
        if let answer = item.referenceAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            text += "\n" + answer
        }
        let title = Self.singleLine(collection.title)
        return MemoryChunk(
            sourceID: item.id, sourceKind: .collectionItem, ordinal: 0, text: text,
            keyText: title.isEmpty ? text : "[\(title)]\n" + text, createdAt: item.createdAt)
    }

    /// One chunk for a fact: `[date it became true] statement`, plus
    /// `(until date)` once it was invalidated. `nil` for a blank statement.
    public func chunk(for fact: FactSnapshot) -> MemoryChunk? {
        let statement = Self.singleLine(fact.statement)
        guard !statement.isEmpty else { return nil }
        var keyText = "[\(formatted(fact.validFrom))] " + statement
        if let invalidatedAt = fact.invalidatedAt { keyText += " (until \(formatted(invalidatedAt)))" }
        return MemoryChunk(
            sourceID: fact.id, sourceKind: .fact, ordinal: 0, text: statement, keyText: keyText,
            createdAt: fact.validFrom)
    }

    // MARK: - Helpers

    func fits(_ text: String) -> Bool {
        tokenCounter.tokenCount(text) <= policy.maximumTokens
    }

    /// Splits a body so that `prefix` + newline + each piece fits.
    func splitter(prefix: String) -> TextSplitter {
        let counter = tokenCounter
        let maximum = policy.maximumTokens
        let lead = prefix.isEmpty ? "" : prefix + "\n"
        return TextSplitter { counter.tokenCount(lead + $0) <= maximum }
    }

    /// `prefix`, the body, and as much of the end of `context` as fits,
    /// after `Earlier:`.
    func keyText(prefix: String, body: String, context: String?) -> String {
        let base = Self.joined(prefix, body)
        guard policy.exchangeOverlap > 0, let context else { return base }
        let counter = tokenCounter
        let maximum = policy.maximumTokens
        let lead = base + "\nEarlier: "
        guard let tail = TextSplitter(fits: { counter.tokenCount(lead + $0) <= maximum }).suffix(of: context) else {
            return base
        }
        return lead + tail
    }

    /// `March 14, 2026` in the policy's time zone. Spelled out by hand
    /// (Gregorian, English month names) so key texts, and their hashes,
    /// don't depend on the device's locale.
    func formatted(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = policy.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = Self.monthNames[max(0, min(11, (parts.month ?? 1) - 1))]
        return "\(month) \(parts.day ?? 1), \(parts.year ?? 1970)"
    }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]

    /// `prefix` and `body` on separate lines, or just `body`.
    static func joined(_ prefix: String, _ body: String) -> String {
        prefix.isEmpty ? body : prefix + "\n" + body
    }

    /// Whitespace runs (newlines included) collapsed to single spaces.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
