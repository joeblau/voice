import Accelerate
import BlauCore
import Testing

@testable import BlauAudio

/// The soak test's mixed audio (#76): the user's lines with an interlude of
/// TV dialogue and silence before every new topic.
@Suite struct ConversationAudioScriptInterludeTests {
    let conversation = ScriptedConversation(exchanges: 13, exchangesPerTopic: 6)
    let interlude = ConversationAudioScript.Interlude.tvAndSilence

    @Test func withoutAnInterludeNothingChanges() {
        let plain = ConversationAudioScript(conversation: conversation)
        let explicit = ConversationAudioScript(conversation: conversation, interlude: nil)
        #expect(plain.backgroundBursts.isEmpty)
        #expect(plain.lines == explicit.lines)
        #expect(plain.totalSamples == explicit.totalSamples)
        #expect(plain.samples(in: 0..<64_000) == explicit.samples(in: 0..<64_000))
    }

    @Test func anInterludeComesBeforeEveryNewTopic() {
        let plain = ConversationAudioScript(conversation: conversation)
        let mixed = ConversationAudioScript(conversation: conversation, interlude: interlude)
        let interludeSamples = interlude.duration.sampleCount(sampleRate: 16_000)
        #expect(mixed.lines.count == 13)
        for (index, line) in mixed.lines.enumerated() {
            // Lines 6 and 12 start new topics: one interlude before each.
            let shift = Int64(index / 6) * interludeSamples
            #expect(line.sampleRange.lowerBound == plain.lines[index].sampleRange.lowerBound + shift)
            #expect(line.text == plain.lines[index].text)
        }
        #expect(mixed.totalSamples == plain.totalSamples + 2 * interludeSamples)
        #expect(interlude.duration == .seconds(64))
    }

    @Test func backgroundSpeechStaysInsideTheInterludes() throws {
        let mixed = ConversationAudioScript(conversation: conversation, interlude: interlude)
        #expect(mixed.backgroundBursts.count >= 6, "two interludes of 30 s, bursts of 3 to 8 s")
        let margin = interlude.margin.sampleCount(sampleRate: 16_000)
        for burst in mixed.backgroundBursts {
            #expect(burst.count >= 16_000)
            #expect(burst.count <= 8 * 16_000)
            // Never within the margin of a user line.
            for line in mixed.lines {
                #expect(
                    burst.upperBound + margin <= line.sampleRange.lowerBound
                        || burst.lowerBound >= line.sampleRange.upperBound)
            }
        }
        for (burst, next) in zip(mixed.backgroundBursts, mixed.backgroundBursts.dropFirst()) {
            #expect(next.lowerBound - burst.upperBound >= 16_000, "a pause between bursts")
        }
        // The first interlude's background ends within its 30 s.
        let first = try #require(mixed.backgroundBursts.first)
        let line5End = mixed.lines[5].sampleRange.upperBound
        #expect(first.lowerBound > line5End)
        let firstInterlude = mixed.backgroundBursts.filter { $0.lowerBound < mixed.lines[6].sampleRange.lowerBound }
        let span = try #require(firstInterlude.last).upperBound - first.lowerBound
        #expect(span <= interlude.background.sampleCount(sampleRate: 16_000))
    }

    @Test func theBackgroundIsAudibleAndTheSilenceIsQuiet() throws {
        let mixed = ConversationAudioScript(conversation: conversation, interlude: interlude)
        let burst = try #require(mixed.backgroundBursts.first)
        let tv = 20 * log10(vDSP.rootMeanSquare(mixed.samples(in: burst)))
        let speech = 20 * log10(vDSP.rootMeanSquare(mixed.samples(in: mixed.lines[2].sampleRange)))
        #expect(tv > -40, "the VAD must hear the TV: \(tv) dBFS")
        #expect(tv < speech, "quieter than the user: \(tv) vs \(speech) dBFS")
        // The silence after the TV: room noise only.
        let silenceEnd = mixed.lines[6].sampleRange.lowerBound - 16_000
        let silence = mixed.samples(in: (silenceEnd - 10 * 16_000)..<silenceEnd)
        let level = 20 * log10(vDSP.rootMeanSquare(silence))
        #expect(level < -50, "noise floor \(level) dBFS")
    }

    @Test func talkerTellsTheUserFromTheBackground() throws {
        let mixed = ConversationAudioScript(conversation: conversation, interlude: interlude)
        let burst = try #require(mixed.backgroundBursts.first)
        let line = mixed.lines[3].sampleRange
        #expect(mixed.talker(in: burst) == .background)
        #expect(mixed.talker(in: line) == .user)
        // A VAD segment reaching a little past either side keeps its talker.
        #expect(mixed.talker(in: (burst.lowerBound - 3_200)..<(burst.upperBound + 3_200)) == .background)
        #expect(mixed.talker(in: (line.lowerBound - 3_200)..<(line.upperBound + 3_200)) == .user)
        let silenceEnd = mixed.lines[6].sampleRange.lowerBound - 16_000
        #expect(mixed.talker(in: (silenceEnd - 16_000)..<silenceEnd) == .nobody)
    }

    @Test func framesTileAcrossAnInterlude() throws {
        let mixed = ConversationAudioScript(conversation: conversation, interlude: interlude)
        let burst = try #require(mixed.backgroundBursts.first)
        let range = (burst.lowerBound - 320 * 3)..<(burst.lowerBound + 320 * 40)
        var tiled: [Float] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let frame = mixed.frame(at: offset, length: 320)
            tiled += frame.samples
            offset = frame.nextSampleOffset
        }
        #expect(tiled == mixed.samples(in: range))
    }

    @Test func aSessionWithInterludesStillLastsTheRequestedTime() {
        let session = ConversationAudioScript.session(lasting: .seconds(600), interlude: interlude)
        #expect(session.duration >= .seconds(600))
        #expect(session.duration < .seconds(600 + 64 + 30))
        #expect(!session.backgroundBursts.isEmpty)
        // Deterministic.
        let again = ConversationAudioScript.session(lasting: .seconds(600), interlude: interlude)
        #expect(again.backgroundBursts == session.backgroundBursts)
        #expect(again.lines == session.lines)
    }
}
