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

/// Builds the verification gate for one conversation: the enrolled
/// voiceprint from the synced store, the WeSpeaker model and the Voice ID
/// sensitivity, over the conversation's capture history.
///
/// Returns `nil`, so every utterance goes through as before, when the
/// `voiceIDEnabled` flag is off or no voiceprint is enrolled (onboarding
/// lets the user skip enrollment, and Settings explains that Blau then
/// answers anyone). If a voiceprint is enrolled but the gate can't be built
/// (the model isn't installed, the store can't be read), it also returns
/// `nil` and logs an error: the conversation still works, unprotected,
/// rather than not hearing the user at all.
struct VoiceIDGateLoader: Sendable {
    let load: @MainActor @Sendable (_ history: any CaptureFrameSource) async -> VerificationGate?

    /// The live gate.
    @MainActor
    static func live(
        persistence: PersistenceController, models: ModelManager, flags: FeatureFlags, settings: VoiceIDSettings
    ) -> VoiceIDGateLoader {
        VoiceIDGateLoader { history in
            guard flags.isEnabled(.voiceIDEnabled) else {
                Log.voiceID.notice("Voice ID is off: every utterance is sent")
                return nil
            }
            guard let container = persistence.stack?.container else {
                Log.voiceID.error("The store isn't open: voice ID can't read the voiceprint")
                return nil
            }
            let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM
            let status: VoiceprintStatus
            do {
                status = try await SwiftDataVoiceprintStore(modelContainer: container).status(for: model)
            } catch {
                Log.voiceID.error("Reading the voiceprint failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            guard let voiceprint = status.voiceprint else {
                Log.voiceID.notice(
                    "No usable voiceprint (\(String(describing: status), privacy: .public)): every utterance is sent")
                return nil
            }
            guard let directory = models.directory(for: .speakerEmbedding) else {
                Log.voiceID.error("The voice ID model isn't installed: the gate is off for this conversation")
                return nil
            }
            do {
                let embedder = try await WeSpeakerEmbedder.load(modelDirectory: directory)
                let verifier = try SpeakerVerifier(
                    embedder: embedder, voiceprint: voiceprint, config: { settings.currentConfig() })
                Log.voiceID.notice(
                    "Voice ID gate on: \(voiceprint.clipCount, privacy: .public) clip(s) from \(voiceprint.sets.count, privacy: .public) device(s)"
                )
                return VerificationGate(verifier: verifier, history: history)
            } catch {
                Log.voiceID.error(
                    "The voice ID gate couldn't start: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }
}
