import BlauCore

/// BlauVoiceID: Speaker embeddings (WeSpeaker ResNet34-LM), enrollment, the
/// accept / reject / uncertain verification gate and language ID.
///
/// See docs/architecture.md for the modules it may depend on.
public enum BlauVoiceIDModule: BlauModule {
    public static let summary = "Speaker embeddings, enrollment, the verification gate and language ID"
}
