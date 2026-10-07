import BlauAudio
import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import BlauTranscription
import BlauVoiceID

/// Every BlauKit module the app links, lowest layer first (the order in
/// docs/architecture.md). The composition root builds on these; diagnostics
/// can list them.
enum BlauKitModules {
    static let all: [any BlauModule.Type] = [
        BlauCoreModule.self,
        BlauTelemetryModule.self,
        BlauAudioModule.self,
        BlauPersistenceModule.self,
        BlauTranscriptionModule.self,
        BlauVoiceIDModule.self,
        BlauRealtimeModule.self,
        BlauTopicsModule.self,
        BlauMemoryModule.self,
    ]
}
