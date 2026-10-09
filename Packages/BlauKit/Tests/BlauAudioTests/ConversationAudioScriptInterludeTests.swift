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

    /// The Parakeet soak's speech (`SOAK_ASR=parakeet`): each topic's lines
    /// are cut from that topic's own clip (synthesized speech of its
    /// sentences on a device), so a model has words to transcribe and the
    /// segmenter the topic's vocabulary. Timing doesn't change.
    @Test func topicVoicesSpeakEachTopicsLines() throws {
        let topics = Set(conversation.exchanges.map(\.topic))
        #expect(topics.count == 3)
        // A constant level per topic, so where each sample came from shows.
        var levels: [String: Float] = [:]
        for (index, topic) in topics.sorted().enumerated() { levels[topic] = Float(index + 1) / 10 }
        let voices = levels.mapValues { AudioFixture(samples: [Float](repeating: $0, count: 4_000), source: "clip") }
        let voiced = ConversationAudioScript(
            conversation: conversation, noiseLevel: 0, interlude: interlude, topicVoices: voices)
        let plain = ConversationAudioScript(conversation: conversation, noiseLevel: 0, interlude: interlude)
        #expect(voiced.lines == plain.lines)
        #expect(voiced.totalSamples == plain.totalSamples)
        #expect(voiced.backgroundBursts == plain.backgroundBursts)
        #expect(voiced.source == "clip, a clip per topic")
        for line in voiced.lines {
            let speech = voiced.samples(in: line.sampleRange)
            let level = try #require(levels[line.topic])
            #expect(speech.allSatisfy { $0 == level }, "line \(line.exchange) is spoken in \(line.topic)'s voice")
        }
        // Topics without a clip keep the default voice.
        let partial = ConversationAudioScript(
            conversation: conversation, noiseLevel: 0, interlude: interlude,
            topicVoices: [conversation.exchanges[0].topic: try #require(voices[conversation.exchanges[0].topic])])
        let later = try #require(partial.lines.last)
        #expect(partial.samples(in: later.sampleRange) == plain.samples(in: later.sampleRange))

        // session(lasting:) passes them through (with the room noise, under
        // 0.004 at its default level).
        let session = ConversationAudioScript.session(
            lasting: .seconds(120), interlude: interlude, topicVoices: voices)
        let first = try #require(session.lines.first)
        let firstLevel = try #require(levels[first.topic])
        #expect(session.samples(in: first.sampleRange).allSatisfy { abs($0 - firstLevel) < 0.004 })
    }

    @Test func topicPassagesHoldEachTopicsOwnSentences() throws {
        let passages = ConversationAudioScript.topicPassages(exchangesPerTopic: 6)
        let topics = ScriptedConversation.standardTopics
        #expect(Set(passages.keys) == Set(topics.map(\.name)))
        let conversation = ScriptedConversation(exchanges: 6 * topics.count, exchangesPerTopic: 6)
        for exchange in conversation.exchanges {
            let passage = try #require(passages[exchange.topic])
            #expect(passage.contains(exchange.user))
        }
        for topic in topics {
            let passage = try #require(passages[topic.name])
            #expect(ScriptedConversation.words(in: passage).count > 50, "about half a minute of speech")
        }
    }
}
