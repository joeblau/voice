import BlauAudio
import BlauCore
import BlauPersistence
import BlauTranscription
import BlauVoiceID
import Foundation

/// What the guided voice enrollment (#46) records with and embeds with in
/// this environment.
///
/// The live app records through the conversation's own voice-processing
/// capture (`ConversationEnrollmentAudio`) and embeds with the downloaded
/// WeSpeaker model; every other environment synthesizes speech
/// (`ScriptedEnrollmentAudio`) and embeds with `ScriptedSpeakerEmbedder`,
/// so previews and UI tests never touch the microphone or a model.
struct VoiceEnrollmentServices: Sendable {
    /// The microphone for one enrollment.
    let makeAudio: @Sendable () -> any EnrollmentAudioSource
    /// Loads the speaker embedder.
    let loadEmbedder: @Sendable () async throws -> any SpeakerEmbedder
    /// This device's model, the key of its enrollment set.
    let deviceModel: String

    /// Why the embedder couldn't load.
    enum LoadError: Error, CustomStringConvertible {
        case modelNotInstalled

        var description: String { "The voice ID model isn't installed yet" }
    }

    /// The real microphone and model.
    static func live(audio: ConversationAudio, models: ModelManager) -> VoiceEnrollmentServices {
        VoiceEnrollmentServices(
            makeAudio: { ConversationEnrollmentAudio(audio: audio) },
            loadEmbedder: {
                guard let directory = await models.directory(for: .speakerEmbedding) else {
                    throw LoadError.modelNotInstalled
                }
                return try await WeSpeakerEmbedder.load(modelDirectory: directory)
            },
            deviceModel: VoiceprintDevice.currentModel)
    }

    /// Synthetic speech and embeddings. `speed` paces the audio (UI tests
    /// run faster than real time); `nil` delivers it as fast as it is read.
    static func scripted(speed: Double?) -> VoiceEnrollmentServices {
        VoiceEnrollmentServices(
            makeAudio: { ScriptedEnrollmentAudio(speed: speed) },
            loadEmbedder: { ScriptedSpeakerEmbedder() },
            deviceModel: VoiceprintDevice.currentModel)
    }
}

extension AppEnvironment {
    /// A guided enrollment for `plan`, storing into the synced store, or
    /// `nil` until the store is open.
    func makeVoiceEnrollment(plan: EnrollmentPlan) -> VoiceEnrollment? {
        guard let container = modelContainer else { return nil }
        let services = voiceEnrollment
        return VoiceEnrollment(
            plan: plan, audio: services.makeAudio(), loadEmbedder: services.loadEmbedder,
            store: SwiftDataVoiceprintStore(modelContainer: container), deviceModel: services.deviceModel,
            clock: clock)
    }
}
