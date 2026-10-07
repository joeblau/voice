import Foundation

/// A timed sequence of transcript events for `FakeTranscriber` to replay.
///
/// Write one by hand with `init(steps:)`, or let `speaking(_:...)` turn
/// lines of text into the partials and finals a streaming recognizer would
/// produce for them.
public struct TranscriptScript: Hashable, Sendable {
    /// One event and how long to wait before emitting it.
    public struct Step: Hashable, Sendable {
        /// Time to wait after the previous step (or after `start()`).
        public var delay: Duration
        public var event: TranscriptEvent

        public init(delay: Duration, event: TranscriptEvent) {
            self.delay = delay
            self.event = event
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// The finished utterances in the script, in order.
    public var finals: [Utterance] {
        steps.compactMap { step in
            if case .final(let utterance) = step.event { utterance } else { nil }
        }
    }

    /// The time from `start()` to the last event.
    public var duration: Duration {
        steps.reduce(.zero) { $0 + $1.delay }
    }

    /// A script that speaks each of `lines` the way a streaming recognizer
    /// reports it: one partial per word, growing word by word, then a final
    /// utterance once the end of the utterance is detected.
    ///
    /// - Parameters:
    ///   - lines: What is said, one utterance per line. Blank lines are
    ///     skipped.
    ///   - conversationID: The conversation the utterances belong to.
    ///   - speaker: Who speaks. User utterances are marked as accepted by
    ///     the voice gate.
    ///   - startedAt: Wall-clock time of the script's start, for the
    ///     utterances' `startedAt`.
    ///   - wordDuration: How long each word takes; also the gap between
    ///     partials.
    ///   - endOfUtteranceDelay: Silence after the last word before the final
    ///     is emitted.
    ///   - pauseBetweenLines: Silence between one utterance's final and the
    ///     next utterance's first word.
    public static func speaking(
        _ lines: [String],
        conversationID: ConversationID = ConversationID(),
        speaker: Speaker = .user,
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        wordDuration: Duration = .milliseconds(250),
        endOfUtteranceDelay: Duration = .milliseconds(600),
        pauseBetweenLines: Duration = .milliseconds(900)
    ) -> TranscriptScript {
        var steps: [Step] = []
        var elapsed = Duration.zero
        var pendingPause = Duration.zero

        for line in lines {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }

            let lineStart = elapsed + pendingPause
            var delay = pendingPause
            for count in 1...words.count {
                delay += wordDuration
                let range = TimeRange(start: lineStart, duration: wordDuration * count)
                let text = words.prefix(count).joined(separator: " ")
                steps.append(Step(delay: delay, event: .partial(text: text, range: range)))
                delay = .zero
            }

            let range = TimeRange(start: lineStart, duration: wordDuration * words.count)
            let utterance = Utterance(
                conversationID: conversationID,
                speaker: speaker,
                text: words.joined(separator: " "),
                timeRange: range,
                startedAt: startedAt.addingTimeInterval(lineStart.timeInterval),
                speakerDecision: speaker == .user ? .accept : nil
            )
            steps.append(Step(delay: endOfUtteranceDelay, event: .final(utterance)))

            elapsed = range.end + endOfUtteranceDelay
            pendingPause = pauseBetweenLines
        }
        return TranscriptScript(steps: steps)
    }

    /// A short user monologue for previews and demos.
    public static let sample = TranscriptScript.speaking([
        "I want to practice for my YC interview",
        "Start with the question about what we are building",
        "Then ask me why now",
    ])
}
