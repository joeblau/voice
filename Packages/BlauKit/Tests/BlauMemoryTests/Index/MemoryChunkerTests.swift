import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Memory chunker: exchanges")
struct ExchangeChunkingTests {
    typealias Support = IndexTestSupport

    @Test func utterancesGroupIntoExchangesLikeTheTopicSegmenter() {
        let conversation = Support.conversation([
            (.user, "Hi."),
            (.user, "We booked the Japan flights."),
            (.agent, "Great news."),
            (.agent, "Book Kyoto hotels soon."),
            (.system, "Session reconnected."),
            (.user, "Thanks."),
            (.agent, "   "),
            (.agent, "Have a good trip."),
        ])
        let exchanges = MemoryChunker.exchanges(in: conversation)
        #expect(exchanges.count == 2)
        #expect(exchanges[0].userText == "Hi. We booked the Japan flights.")
        #expect(exchanges[0].agentText == "Great news. Book Kyoto hotels soon.")
        #expect(
            exchanges[0].text == "User: Hi. We booked the Japan flights.\nBlau: Great news. Book Kyoto hotels soon.")
        #expect(exchanges[0].startedAt == Support.t0)
        #expect(exchanges[1].text == "User: Thanks.\nBlau: Have a good trip.")
        #expect(exchanges[1].utteranceIDs.count == 2)
    }

    @Test func anExchangeTheAgentOpensHasNoUserLine() {
        let conversation = Support.conversation([(.agent, "Welcome back."), (.user, "Hello.")])
        let exchanges = MemoryChunker.exchanges(in: conversation)
        #expect(exchanges.map(\.text) == ["Blau: Welcome back.", "User: Hello."])
    }

    @Test func utterancesAreOrderedByStartTime() {
        var conversation = Support.conversation([(.user, "First question?"), (.agent, "First answer.")])
        conversation.utterances.reverse()
        #expect(MemoryChunker.exchanges(in: conversation).map(\.text) == ["User: First question?\nBlau: First answer."])
    }

    @Test func keysCarryTheDateTopicFactsAndThePreviousExchange() throws {
        let topic = ConversationSnapshot.TopicSnapshot(id: UUID(), title: "Japan trip")
        let conversation = Support.conversation(
            topic: topic,
            [
                (.user, "We land in Tokyo on April 2nd."),
                (.agent, "Spring is cherry blossom season."),
                (.user, "Is the JR Pass worth it?"),
                (.agent, "Not for your route."),
            ])
        let firstUser = conversation.utterances[0].id
        let chunks = Support.chunker.chunks(
            for: conversation,
            factsByUtterance: [firstUser: ["User lands in Tokyo on April 2", "User lands in Tokyo on April 2", " "]])

        try #require(chunks.count == 2)
        #expect(
            chunks[0].keyText == """
                [January 15, 2026] [Japan trip] facts: User lands in Tokyo on April 2
                User: We land in Tokyo on April 2nd.
                Blau: Spring is cherry blossom season.
                """)
        #expect(chunks[0].text == "User: We land in Tokyo on April 2nd.\nBlau: Spring is cherry blossom season.")
        #expect(
            chunks[1].keyText == """
                [January 15, 2026] [Japan trip]
                User: Is the JR Pass worth it?
                Blau: Not for your route.
                Earlier: User: We land in Tokyo on April 2nd.
                Blau: Spring is cherry blossom season.
                """)
        #expect(chunks[1].text == "User: Is the JR Pass worth it?\nBlau: Not for your route.")
        for (ordinal, chunk) in chunks.enumerated() {
            #expect(chunk.ordinal == ordinal)
            #expect(chunk.id == MemoryChunk.id(kind: .conversation, sourceID: conversation.id, ordinal: ordinal))
            #expect(chunk.sourceKind == .conversation)
            #expect(chunk.sourceID == conversation.id)
            #expect(chunk.conversationID == conversation.id)
            #expect(chunk.topicID == topic.id)
            #expect(chunk.contentHash == MemoryChunk.contentHash(of: chunk.keyText))
        }
        #expect(chunks[1].createdAt == Support.t0.addingTimeInterval(60))
    }

    @Test func aPlaceholderTopicAndNoOverlapLeaveJustTheDate() {
        var policy = Support.policy
        policy.exchangeOverlap = 0
        let conversation = Support.conversation(
            topic: ConversationSnapshot.TopicSnapshot(id: UUID(), title: nil),
            [(.user, "One."), (.agent, "Two."), (.user, "Three."), (.agent, "Four.")])
        let chunks = MemoryChunker(policy: policy).chunks(for: conversation)
        #expect(
            chunks.map(\.keyText) == [
                "[January 15, 2026]\nUser: One.\nBlau: Two.", "[January 15, 2026]\nUser: Three.\nBlau: Four.",
            ])
    }

    @Test func datesAreInThePolicysTimeZone() {
        let lateEvening = Date(timeIntervalSince1970: 1_768_519_800)  // 2026-01-15 23:30 UTC
        let conversation = Support.conversation(start: lateEvening, [(.user, "Good night."), (.agent, "Sleep well.")])
        let utc = MemoryChunker(policy: ChunkingPolicy.forSequenceLength(128, timeZone: Support.utc))
        let tokyo = MemoryChunker(
            policy: ChunkingPolicy.forSequenceLength(128, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        #expect(utc.chunks(for: conversation)[0].keyText.hasPrefix("[January 15, 2026]\n"))
        #expect(tokyo.chunks(for: conversation)[0].keyText.hasPrefix("[January 16, 2026]\n"))
    }

    @Test func aLongExchangeIsSplitSoEveryKeyFitsTheModel() throws {
        let sentences = (1...40).map { "Sentence number \($0) explains another detail of the launch plan." }
        let conversation = Support.conversation([
            (.user, "Walk me through the launch plan."), (.agent, sentences.joined(separator: " ")),
            (.user, "Thanks, that helps."), (.agent, "Any time."),
        ])
        let chunker = Support.chunker
        let chunks = chunker.chunks(for: conversation)
        #expect(chunks.count > 3)
        for chunk in chunks {
            #expect(chunker.tokenCounter.tokenCount(chunk.keyText) <= chunker.policy.maximumTokens, "\(chunk.keyText)")
        }
        // The pieces of the long exchange hold every sentence once, in order.
        let long = chunks.dropLast().map(\.text).joined(separator: " ")
        let expected = "User: Walk me through the launch plan.\nBlau: " + sentences.joined(separator: " ")
        #expect(long.split(whereSeparator: \.isWhitespace) == expected.split(whereSeparator: \.isWhitespace))
        // The next exchange's overlap is the end of the long one.
        let last = try #require(chunks.last)
        #expect(last.text == "User: Thanks, that helps.\nBlau: Any time.")
        #expect(last.keyText.contains("\nEarlier: …"))
        #expect(last.keyText.hasSuffix("Sentence number 40 explains another detail of the launch plan."))
        #expect(Array(chunks.map(\.ordinal)) == Array(0..<chunks.count))
    }

    @Test func factsBeyondHalfTheBudgetAreLeftOut() {
        let conversation = Support.conversation([(.user, "Here is everything about me."), (.agent, "Noted.")])
        let facts = (1...5).map { "User has fact number \($0) which is a fairly long statement about their life" }
        let chunker = Support.chunker
        let chunk = chunker.chunks(for: conversation, factsByUtterance: [conversation.utterances[0].id: facts])[0]
        let prefix = String(chunk.keyText.split(separator: "\n")[0])
        #expect(prefix.contains("facts: User has fact number 1"))
        #expect(!prefix.contains("fact number 5"))
        #expect(chunker.tokenCounter.tokenCount(prefix) <= chunker.policy.maximumTokens / 2)
    }

    @Test func chunkingIsDeterministic() {
        let conversation = Support.conversation([(.user, "Same input."), (.agent, "Same output.")])
        #expect(Support.chunker.chunks(for: conversation) == Support.chunker.chunks(for: conversation))
    }

    @Test func aConversationWithNothingSaidHasNoChunks() {
        let conversation = Support.conversation([(.system, "Started."), (.user, "  ")])
        #expect(Support.chunker.chunks(for: conversation).isEmpty)
    }
}

@Suite("Memory chunker: documents, collection items and facts")
struct DocumentChunkingTests {
    typealias Support = IndexTestSupport

    static let pricing = String(
        repeating: "Larderly costs one hundred forty nine dollars per location per month. ", count: 4)
    static let enterprise = String(
        repeating: "Groups with more than ten locations get custom pricing and a success manager. ", count: 4)

    static func document(_ body: String, title: String = "Pricing") -> DocumentSnapshot {
        DocumentSnapshot(id: UUID(), kind: .company, title: title, body: body, updatedAt: Support.t0)
    }

    @Test func sectionsLongEnoughToStandAloneSplitAtHeadings() throws {
        let document = Self.document(
            """
            # Plans

            \(Self.pricing)

            ## Enterprise
            \(Self.enterprise)
            """)
        let chunks = Support.chunker.chunks(for: document)
        try #require(chunks.count == 2)
        #expect(chunks[0].keyText.hasPrefix("[Pricing] [Plans]\n# Plans\nLarderly costs"))
        #expect(chunks[1].keyText.hasPrefix("[Pricing] [Plans › Enterprise]\n## Enterprise\nGroups with"))
        #expect(chunks[0].text.hasPrefix("# Plans\nLarderly costs"))
        for (ordinal, chunk) in chunks.enumerated() {
            #expect(chunk.sourceKind == .document)
            #expect(chunk.sourceID == document.id)
            #expect(chunk.ordinal == ordinal)
            #expect(chunk.createdAt == Support.t0)
            #expect(chunk.topicID == nil && chunk.conversationID == nil)
        }
    }

    @Test func shortSectionsAreMergedUntilTheChunkIsLongEnough() throws {
        let document = Self.document(
            """
            # Plans
            Starter is $49.
            ## Pro
            Pro is $149.
            ## Enterprise
            Call us.
            """)
        let chunks = Support.chunker.chunks(for: document)
        try #require(chunks.count == 1)
        #expect(
            chunks[0].keyText == """
                [Pricing] [Plans]
                # Plans
                Starter is $49.

                ## Pro
                Pro is $149.

                ## Enterprise
                Call us.
                """)
    }

    @Test func paragraphsThatDontFitTogetherAreSeparateChunks() {
        let paragraph = String(repeating: "Inventory counts happen every Sunday night before the delivery. ", count: 3)
        let document = Self.document([paragraph, paragraph, paragraph, paragraph].joined(separator: "\n\n"))
        let chunker = Support.chunker
        let chunks = chunker.chunks(for: document)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunker.tokenCounter.tokenCount(chunk.keyText) <= chunker.policy.maximumTokens)
            #expect(chunk.keyText.hasPrefix("[Pricing]\n"))
        }
    }

    @Test func aLongerModelGetsTheIssues200To400TokenChunks() {
        let policy = ChunkingPolicy.forSequenceLength(512)
        #expect(policy.maximumTokens == 400)
        #expect(policy.minimumDocumentTokens == 200)
        #expect(ChunkingPolicy.default.maximumTokens == 112)
    }

    @Test func aDocumentWithoutBodyIsItsTitle() {
        let chunks = Support.chunker.chunks(for: Self.document("  \n ", title: "Ideas for the offsite"))
        #expect(chunks.map(\.keyText) == ["Ideas for the offsite"])
        #expect(Support.chunker.chunks(for: Self.document("", title: " ")).isEmpty)
    }

    @Test func headingParsing() {
        #expect(MemoryChunker.heading(in: "## Team ##")?.title == "Team")
        #expect(MemoryChunker.heading(in: "### Q3 goals")?.level == 3)
        #expect(MemoryChunker.heading(in: "#hashtag") == nil)
        #expect(MemoryChunker.heading(in: "####### seven") == nil)
        #expect(MemoryChunker.heading(in: "# ") == nil)
    }

    @Test func aCollectionItemIsOneChunkKeyedWithItsCollection() throws {
        let item = DocumentSnapshot.ItemSnapshot(
            id: UUID(), ordinal: 0, prompt: " What are you building? ", referenceAnswer: "A voice app that remembers.",
            createdAt: Support.t0)
        let collection = DocumentSnapshot(
            id: UUID(), kind: .collection, title: "YC interview", body: "", updatedAt: Support.t0, items: [item])
        let chunk = try #require(Support.chunker.chunk(for: item, in: collection))
        #expect(chunk.sourceKind == .collectionItem)
        #expect(chunk.sourceID == item.id)
        #expect(chunk.text == "What are you building?\nA voice app that remembers.")
        #expect(chunk.keyText == "[YC interview]\nWhat are you building?\nA voice app that remembers.")
        #expect(chunk.id == MemoryChunk.id(kind: .collectionItem, sourceID: item.id, ordinal: 0))

        let blank = DocumentSnapshot.ItemSnapshot(id: UUID(), ordinal: 1, prompt: "  ", createdAt: Support.t0)
        #expect(Support.chunker.chunk(for: blank, in: collection) == nil)
    }

    @Test func aFactChunkCarriesWhenItWasTrue() throws {
        let fact = FactSnapshot(
            id: UUID(), statement: "User works at\nStripe", validFrom: Support.t0,
            invalidatedAt: Support.t0.addingTimeInterval(86_400 * 31))
        let chunk = try #require(Support.chunker.chunk(for: fact))
        #expect(chunk.text == "User works at Stripe")
        #expect(chunk.keyText == "[January 15, 2026] User works at Stripe (until February 15, 2026)")
        #expect(chunk.createdAt == Support.t0)
        #expect(chunk.sourceKind == .fact)
        #expect(Support.chunker.chunk(for: FactSnapshot(id: UUID(), statement: " ", validFrom: Support.t0)) == nil)
    }
}

@Suite("Memory chunk identity")
struct MemoryChunkIdentityTests {
    /// Pinned: changing the derivation gives every chunk a new id, which
    /// re-inserts (and re-embeds) the whole index.
    @Test func chunkIDsArePinned() {
        let source = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let id = MemoryChunk.id(kind: .conversation, sourceID: source, ordinal: 3)
        #expect(id == MemoryChunk.id(kind: .conversation, sourceID: source, ordinal: 3))
        #expect(id != MemoryChunk.id(kind: .conversation, sourceID: source, ordinal: 4))
        #expect(id != MemoryChunk.id(kind: .document, sourceID: source, ordinal: 3))
        #expect(id.uuidString == "A8B7962D-1449-8F4A-9CFA-18832269BC32")
        // RFC 9562 version 8, variant 10.
        #expect(id.uuid.6 >> 4 == 8)
        #expect(id.uuid.8 >> 6 == 2)
    }

    @Test func contentHashIsSHA256Hex() {
        #expect(
            MemoryChunk.contentHash(of: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Keyword query")
struct KeywordQueryTests {
    @Test func wordsAreQuotedAndJoinedWithOr() {
        #expect(KeywordQuery("When did I start running?")?.pattern == "\"start\" OR \"running\"")
        #expect(KeywordQuery("Menya Kotori, near Namba")?.terms == ["menya", "kotori", "near", "namba"])
    }

    @Test func ftsSyntaxIsNeverInterpreted() {
        #expect(KeywordQuery("ramen AND \"yuzu\" NOT shio*")?.pattern == "\"ramen\" OR \"yuzu\" OR \"shio\"")
        #expect(KeywordQuery("NEAR(a b)")?.terms == ["near", "b"])
    }

    @Test func diacriticsAndCaseAreFolded() {
        #expect(KeywordQuery("Café CRÈME brûlée")?.terms == ["cafe", "creme", "brulee"])
    }

    @Test func stopWordsStayOnlyWhenNothingElseIsLeft() {
        #expect(KeywordQuery("what was it")?.terms == ["what", "was", "it"])
        #expect(KeywordQuery("the the THE")?.terms == ["the"])
        #expect(KeywordQuery("   ?! ") == nil)
    }

    @Test func termsAreCapped() {
        let query = KeywordQuery((0..<100).map { "word\($0)" }.joined(separator: " "))
        #expect(query?.terms.count == KeywordQuery.maximumTerms)
    }
}
