/// One step of the guided enrollment: what the user is asked to do while a
/// clip is recorded.
///
/// The four kinds cover the ways the user will really talk to Blau, so the
/// voiceprint doesn't only know their reading voice at a fixed distance
/// (issue #46): read a sentence, answer a question in their own words,
/// speak quietly, and speak with the phone at arm's length. The app supplies
/// the wording (`EnrollmentPromptCopy`); this type carries what the quality
/// checks need to know about the step.
public enum EnrollmentPrompt: String, Hashable, Codable, Sendable, CaseIterable, CustomStringConvertible {
    /// Read a displayed sentence aloud.
    case readSentence
    /// Answer a question in natural, unscripted speech.
    case answerQuestion
    /// Speak quietly, close to the phone.
    case speakQuietly
    /// Speak with the phone held at arm's length.
    case armsLength

    /// Whether the prompt asks for a softer or more distant voice, so the
    /// level checks are relaxed for it (``EnrollmentQualityPolicy``).
    public var expectsLowLevel: Bool {
        switch self {
        case .readSentence, .answerQuestion: false
        case .speakQuietly, .armsLength: true
        }
    }

    public var description: String { rawValue }
}

/// What a guided capture records: the prompts, in order, and how much speech
/// each clip needs.
///
/// - ``enrollment``: the first enrollment (or a re-enrollment) on any
///   device. Four prompts of about 5 s of speech: 20 s in all, comfortably
///   inside the one-minute budget with reading time and analysis.
/// - ``topUp``: a device that already has the synced voiceprint adds its own
///   microphones: three prompts, about 15 s (issue #46).
public struct EnrollmentPlan: Hashable, Sendable {
    /// What the capture is for.
    public enum Purpose: String, Hashable, Sendable {
        /// A new voiceprint, replacing any existing one.
        case enrollment
        /// This device's enrollment set, added to the existing voiceprint.
        case topUp
    }

    public let purpose: Purpose

    /// The prompts, in the order they are asked.
    public let prompts: [EnrollmentPrompt]

    /// How much detected speech a clip needs before it stops by itself.
    public let speechPerClip: Duration

    /// The longest a clip records, speech or not. Bounds the whole capture:
    /// `prompts.count × maximumClipDuration` is the worst case.
    public let maximumClipDuration: Duration

    /// How long the user must pause after reaching ``speechPerClip`` before
    /// the clip stops, so a sentence isn't cut mid-word.
    public let trailingSilence: Duration

    /// - Precondition: At least one prompt, `0 < speechPerClip <
    ///   maximumClipDuration`, and a non-negative trailing silence.
    public init(
        purpose: Purpose,
        prompts: [EnrollmentPrompt],
        speechPerClip: Duration = .seconds(5),
        maximumClipDuration: Duration = .seconds(12),
        trailingSilence: Duration = .milliseconds(500)
    ) {
        precondition(!prompts.isEmpty, "A plan needs at least one prompt")
        precondition(speechPerClip > .zero && speechPerClip < maximumClipDuration, "Invalid clip durations")
        precondition(trailingSilence >= .zero, "The trailing silence can't be negative")
        self.purpose = purpose
        self.prompts = prompts
        self.speechPerClip = speechPerClip
        self.maximumClipDuration = maximumClipDuration
        self.trailingSilence = trailingSilence
    }

    /// Four prompts × ~5 s of natural speech.
    public static let enrollment = EnrollmentPlan(
        purpose: .enrollment, prompts: [.readSentence, .answerQuestion, .speakQuietly, .armsLength])

    /// The optional 15 s top-up for a device that has the synced voiceprint
    /// but no enrollment set of its own.
    public static let topUp = EnrollmentPlan(purpose: .topUp, prompts: [.readSentence, .answerQuestion, .armsLength])

    /// The speech the plan collects when every clip is accepted first time.
    public var totalSpeech: Duration { speechPerClip * prompts.count }

    /// The longest the recording itself can take when every clip is
    /// accepted first time (each clip at ``maximumClipDuration``).
    public var maximumRecordingDuration: Duration { maximumClipDuration * prompts.count }
}
