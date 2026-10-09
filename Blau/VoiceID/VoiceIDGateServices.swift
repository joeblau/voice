import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTranscription
import BlauVoiceID
import Foundation
import os

/// The voice ID verification gate (#47) as the barge-in monitor's speaker
/// gate (#37): only accepted or uncertain speech interrupts Grok. The two
/// come from BlauKit modules that can't import each other, so the
/// composition root adapts one to the other.
struct VoiceIDBargeInGate: BargeInSpeakerGate {
    let gate: VerificationGate

    func bargeInDecision(for onset: SpeechOnset) async -> SpeakerDecision? {
        await gate.bargeInDecision(for: onset)
    }
}

/// Whether the voice ID gate (#47) guards a conversation, and if not, why.
enum VoiceIDGateStatus: Equatable, Sendable {
    /// Only the enrolled speaker's utterances reach Grok.
    case on
    /// The `voiceIDEnabled` flag is off: every utterance is sent.
    case off
    /// No usable voiceprint (enrollment was skipped): every utterance is
    /// sent, as Settings → Voice ID explains.
    case notEnrolled
    /// A voiceprint is enrolled but the gate couldn't start, so this
    /// conversation runs unprotected: a TV or someone else can reach Grok.
    case unavailable(Reason)

    enum Reason: String, Equatable, Sendable {
        /// The store isn't open, or reading the voiceprint failed.
        case voiceprintUnreadable
        /// The speaker model isn't installed (still downloading).
        case modelNotInstalled
        /// The speaker model failed to load, or doesn't match the
        /// voiceprint.
        case modelFailed
    }

    /// Whether the user expects protection this conversation doesn't have.
    var isDegraded: Bool {
        if case .unavailable = self { true } else { false }
    }

    /// For Settings → Voice ID and the debug screen.
    var summary: String {
        switch self {
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .notEnrolled: String(localized: "Off: no voiceprint")
        case .unavailable: String(localized: "Off for this conversation")
        }
    }

    /// Why voice ID isn't protecting this conversation, for the user.
    var explanation: String? {
        guard case .unavailable(let reason) = self else { return nil }
        let cause =
            switch reason {
            case .voiceprintUnreadable: String(localized: "Your voiceprint couldn't be read.")
            case .modelNotInstalled: String(localized: "The voice ID model is still downloading.")
            case .modelFailed: String(localized: "The voice ID model couldn't start.")
            }
        return cause + " " + String(localized: "Anyone nearby, or a TV, can reach Grok until the next conversation.")
    }
}

/// The verification gate for one conversation, or why there is none.
struct VoiceIDGateLoad {
    let gate: VerificationGate?
    let status: VoiceIDGateStatus
    /// Adaptive voiceprint updates for the conversation (#49): finish it
    /// when the conversation ends, which saves the adapted voiceprint.
    var adapter: VoiceprintAdapter?

    static func without(_ status: VoiceIDGateStatus) -> VoiceIDGateLoad {
        VoiceIDGateLoad(gate: nil, status: status)
    }
}

/// Builds the verification gate for one conversation: the enrolled
/// voiceprint from the synced store, the WeSpeaker model and the Voice ID
/// sensitivity, over the conversation's capture history.
///
/// There is no gate, so every utterance goes through as before, when the
/// `voiceIDEnabled` flag is off or no voiceprint is enrolled (onboarding
/// lets the user skip enrollment, and Settings explains that Blau then
/// answers anyone). If a voiceprint is enrolled but the gate can't be built
/// (the model isn't installed, the store can't be read), there is no gate
/// either, and the status says so (`VoiceIDGateStatus.unavailable`): the
/// conversation still works, unprotected, rather than not hearing the user
/// at all, and Settings → Voice ID tells the user.
struct VoiceIDGateLoader: Sendable {
    let load: @MainActor @Sendable (_ history: any CaptureFrameSource) async -> VoiceIDGateLoad

    /// The live gate.
    @MainActor
    static func live(
        persistence: PersistenceController, models: ModelManager, flags: FeatureFlags, settings: VoiceIDSettings
    ) -> VoiceIDGateLoader {
        VoiceIDGateLoader { history in
            guard flags.isEnabled(.voiceIDEnabled) else {
                Log.voiceID.notice("Voice ID is off: every utterance is sent")
                return .without(.off)
            }
            guard let container = persistence.stack?.container else {
                Log.voiceID.error("The store isn't open: voice ID can't read the voiceprint")
                return .without(.unavailable(.voiceprintUnreadable))
            }
            let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM
            let store = SwiftDataVoiceprintStore(modelContainer: container)
            let status: VoiceprintStatus
            do {
                status = try await store.status(for: model)
            } catch {
                Log.voiceID.error("Reading the voiceprint failed: \(String(describing: error), privacy: .public)")
                return .without(.unavailable(.voiceprintUnreadable))
            }
            guard let voiceprint = status.voiceprint else {
                Log.voiceID.notice(
                    "No usable voiceprint (\(String(describing: status), privacy: .public)): every utterance is sent")
                return .without(.notEnrolled)
            }
            guard let directory = models.directory(for: .speakerEmbedding) else {
                Log.voiceID.error("The voice ID model isn't installed: the gate is off for this conversation")
                return .without(.unavailable(.modelNotInstalled))
            }
            do {
                let embedder = try await WeSpeakerEmbedder.load(modelDirectory: directory)
                // The voiceprint adapts to the owner's clearly accepted
                // speech (#49); the conversation's updates are saved when
                // it ends.
                let verifier = try SpeakerVerifier(
                    embedder: embedder, voiceprint: voiceprint, config: { settings.currentConfig() },
                    adaptation: .standard)
                var adapter: VoiceprintAdapter?
                var onScoredSpeech: (@Sendable (ScoredSpeechSegment) -> Void)?
                if let adaptive = verifier.adaptive {
                    let created = VoiceprintAdapter(voiceprint: adaptive, store: store)
                    adapter = created
                    onScoredSpeech = { segment in created.observe(segment) }
                }
                // Other-language segments the filter (#50) catches are
                // never handed to the adapter.
                let filter = await Self.languageFilter(models: models, settings: settings.languageFilter)
                let gate = VerificationGate(
                    verifier: verifier, history: history, languageFilter: filter, onScoredSpeech: onScoredSpeech)
                let adaptation = adapter == nil ? "off" : "on"
                let drift = Double(voiceprint.adaptationDrift ?? 0)
                Log.voiceID.notice(
                    "Voice ID gate on: \(voiceprint.clipCount, privacy: .public) clip(s) from \(voiceprint.sets.count, privacy: .public) device(s), adaptation \(adaptation, privacy: .public), drift \(drift, format: .fixed(precision: 4), privacy: .public)"
                )
                return VoiceIDGateLoad(gate: gate, status: .on, adapter: adapter)
            } catch {
                Log.voiceID.error(
                    "The voice ID gate couldn't start: \(String(describing: error), privacy: .public)")
                return .without(.unavailable(.modelFailed))
            }
        }
    }

    /// The language filter (#50) for the conversation's gate, or `nil`:
    /// when it is off in Settings (turning it on applies from the next
    /// conversation), or its model isn't installed or doesn't load. Without
    /// it the gate still checks the speaker; only the language check is
    /// skipped. The allowed languages are read for every segment, so
    /// changing them (or turning the filter off) applies at once.
    @MainActor
    static func languageFilter(models: ModelManager, settings: LanguageFilterSettings) async -> LanguageFilter? {
        guard settings.isEnabled else {
            Log.voiceID.notice("The language filter is off: speech in any language is sent")
            return nil
        }
        guard let directory = models.directory(for: .languageID) else {
            Log.voiceID.notice("The language filter's model isn't installed yet: speech in any language is sent")
            return nil
        }
        do {
            let identifier = try await VoxLinguaLanguageIdentifier.load(modelDirectory: directory)
            let allowed = settings.allowedLanguages.map(\.code).sorted().joined(separator: ", ")
            Log.voiceID.notice("Language filter on: \(allowed, privacy: .public)")
            return LanguageFilter(identifier: identifier, allowedLanguages: { settings.currentAllowedLanguages() })
        } catch {
            Log.voiceID.error(
                "The language filter couldn't start: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
