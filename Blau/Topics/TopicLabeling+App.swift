import BlauRealtime
import BlauTopics

extension TopicLabelingService {
    /// The app's topic labeling chain (#53): Apple's on-device model, then
    /// xAI's text API with the user's key from the Keychain when Apple
    /// Intelligence is unavailable, then keyword titles.
    ///
    /// BlauTopics can't import BlauRealtime (they're siblings in the module
    /// graph), so the xAI client is passed in here, at the composition root.
    @MainActor
    static func app(xai: XAIServices) -> TopicLabelingService {
        .standard(textGenerator: XAITextGenerator(client: xai.client))
    }
}
