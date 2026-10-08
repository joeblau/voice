import BlauVoiceID
import Foundation

/// What the guided enrollment says for each prompt.
struct EnrollmentPromptCopy: Equatable {
    /// What to do, for example "Read this aloud".
    let title: String
    /// The sentence to read, or the question to answer.
    let text: String
    /// How to hold the phone, when it matters.
    let hint: String?

    init(_ prompt: EnrollmentPrompt) {
        switch prompt {
        case .readSentence:
            title = String(localized: "Read this aloud")
            text = String(
                localized: "I'm teaching Blau what my voice sounds like, so it only answers me when I talk to it.")
            hint = nil
        case .answerQuestion:
            title = String(localized: "Answer in your own words")
            text = String(localized: "What did you do last weekend, and what are you looking forward to?")
            hint = String(localized: "Keep talking until the bar fills.")
        case .speakQuietly:
            title = String(localized: "Now say this quietly")
            text = String(localized: "Blau should still know it's me when I'm speaking softly late at night.")
            hint = String(localized: "Keep the phone close, as if someone is asleep nearby.")
        case .armsLength:
            title = String(localized: "Hold the phone at arm's length")
            text = String(
                localized: "And it should recognize my voice from across the table, while I cook or walk around.")
            hint = String(localized: "Speak normally, with your arm stretched out.")
        }
    }
}

/// What the guided enrollment says about a rejected clip or a failure.
enum EnrollmentMessages {
    static func issue(_ issue: EnrollmentClipIssue) -> String {
        switch issue {
        case .tooShort:
            String(localized: "We didn't hear enough of your voice. Keep talking until the bar fills.")
        case .tooQuiet:
            String(localized: "That was too quiet. Speak up a little or hold the phone closer.")
        case .tooNoisy:
            String(
                localized: "There's too much background noise. Try somewhere quieter, away from TVs and other voices.")
        case .clipped:
            String(localized: "That was too loud for the microphone. Hold the phone a little farther away.")
        case .inconsistent:
            String(localized: "That didn't sound like your other clips. Make sure only you are speaking.")
        case .doesNotMatchVoiceprint:
            String(localized: "That doesn't match your voiceprint. Make sure only you are speaking.")
        case .unusable:
            String(localized: "That clip couldn't be used. Try again.")
        }
    }

    static let restarted = String(
        localized: "Your clips didn't sound like the same person, so let's start over. Make sure only you are speaking."
    )

    static func failure(_ error: VoiceEnrollmentError) -> String {
        switch error {
        case .modelUnavailable:
            String(localized: "The Voice ID model isn't ready yet. Check Settings → Speech Models, then try again.")
        case .microphoneUnavailable:
            String(
                localized: "Blau can't use the microphone. Allow microphone access in the Settings app, then try again."
            )
        case .microphoneBusy:
            String(localized: "Stop the conversation first, then enroll.")
        case .microphoneStopped:
            String(localized: "The microphone stopped. Try again.")
        case .notEnrolled:
            String(localized: "There's no voiceprint to add to yet. Enroll your voice first.")
        case .needsReenrollment:
            String(localized: "Your voiceprint needs to be re-enrolled first.")
        case .saveFailed:
            String(localized: "Your voiceprint couldn't be saved. Try again.")
        }
    }
}

/// The three checks the quality meter shows for a clip: enough speech, a
/// clean signal, and a voice that matches the other clips.
struct EnrollmentQualityChecks: Equatable {
    enum State: Equatable {
        case pending
        case passed
        case failed
    }

    var duration: State
    var signal: State
    var consistency: State

    /// The checks for a judged clip.
    init(result: VoiceEnrollment.ClipResult) {
        var duration = State.passed
        var signal = State.passed
        var consistency: State = result.issues.isEmpty ? .passed : .pending
        for issue in result.issues {
            switch issue {
            case .tooShort: duration = .failed
            case .tooQuiet, .tooNoisy, .clipped: signal = .failed
            case .inconsistent, .doesNotMatchVoiceprint, .unusable: consistency = .failed
            }
        }
        self.duration = duration
        self.signal = signal
        self.consistency = consistency
    }

    /// The live checks while a clip records: duration fills up, the
    /// signal is judged on the running SNR, consistency waits for the
    /// embedding.
    init(meter: EnrollmentMeter, minimumSignalToNoise: Float) {
        duration = meter.progress >= 1 ? .passed : .pending
        signal = meter.signalToNoise.map { $0 >= minimumSignalToNoise ? .passed : .failed } ?? .pending
        consistency = .pending
    }
}
