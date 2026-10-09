import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauRealtime

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite("Live captions")
struct ChatCaptionTests {
    private func streaming(_ text: String, item: String = "item_1") -> ChatRow {
        ChatRow(
            id: UUID(), role: .agent, text: text, startedAt: t0, kind: .streaming(PlaybackItemID(itemID: item)))
    }

    // MARK: speakingRow

    @Test func noCaptionWhileGrokIsQuiet() {
        let partial = ChatRow(
            id: ChatRow.livePartialID, role: .user, text: "So what about", startedAt: t0, kind: .partial)
        #expect(ChatCaption.speakingRow(in: []) == nil)
        #expect(ChatCaption.speakingRow(in: [partial]) == nil, "the user's speech isn't a caption")
    }

    @Test func theCaptionIsGroksReplyNotTheUsersPartialOrAChip() {
        let reply = streaming("The second week of November.")
        let chip = ChatRow(
            tool: ChatToolCall(id: "call_1", name: "search_memory", startedAt: t0, state: .running))
        let partial = ChatRow(
            id: ChatRow.livePartialID, role: .user, text: "Wait", startedAt: t0, kind: .partial)
        #expect(ChatCaption.speakingRow(in: [chip, reply, partial]) == reply)
    }

    @Test func aReplyOfSeveralItemsCaptionsTheNewest() {
        let first = streaming("Let me check.", item: "item_1")
        let second = streaming("You picked November.", item: "item_2")
        #expect(ChatCaption.speakingRow(in: [first, second]) == second)
    }

    @Test func aFinishedAgentRowIsNotACaption() {
        let finished = ChatRow(id: UUID(), role: .agent, text: "Done.", startedAt: t0)
        #expect(ChatCaption.speakingRow(in: [finished]) == nil)
    }

    // MARK: tail

    @Test func shortTextIsShownWhole() {
        #expect(ChatCaption.tail(of: "  You picked November. ", maxCharacters: 40) == "You picked November.")
        #expect(ChatCaption.tail(of: "", maxCharacters: 40) == "")
    }

    @Test func longTextKeepsItsLatestWholeWordsAfterAnEllipsis() {
        let text = "First, how fast are you growing week over week, and is it organic?"
        let tail = ChatCaption.tail(of: text, maxCharacters: 30)
        #expect(tail == "\u{2026} week, and is it organic?")
        #expect(tail.count <= 30)
        #expect(text.hasSuffix(String(tail.dropFirst(2))), "the caption is the end of the reply")
    }

    @Test func neverCutsAWordInHalf() {
        let word = "Supercalifragilisticexpialidocious"
        #expect(ChatCaption.tail(of: "a \(word)", maxCharacters: 10) == "\u{2026} \(word)")
    }

    @Test func accessibilitySizesShowFewerCharacters() {
        #expect(
            ChatCaption.maxCharacters(isAccessibilitySize: true)
                < ChatCaption.maxCharacters(isAccessibilitySize: false))
    }
}
