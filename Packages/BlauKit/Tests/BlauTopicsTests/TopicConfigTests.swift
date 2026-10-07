import BlauTopics
import Testing

@Suite("TopicConfig")
struct TopicConfigTests {
    /// The defaults are the design in issue #52.
    @Test func defaultsFollowTheDesign() {
        let config = TopicConfig.default
        #expect(config.leftWindow == 3)
        #expect(config.rightWindow == 2)
        #expect(config.thresholdSigmas == 1.0)
        #expect(config.sustainUnits == 2)
        #expect(config.minimumTopicUnits == 4)
        #expect(config.minimumTopicDuration == .seconds(60))
        #expect(config.cooldown == .seconds(30))
        #expect(config.validationError == nil)
        #expect(TopicConfig.contextualEmbedding.validationError == nil)
        #expect(TopicConfig.contextualEmbedding.minimumDepth < config.minimumDepth)
    }

    @Test func invalidValuesAreReported() {
        let mutations: [(String, (inout TopicConfig) -> Void)] = [
            ("leftWindow", { $0.leftWindow = 0 }),
            ("rightWindow", { $0.rightWindow = 0 }),
            ("thresholdSigmas", { $0.thresholdSigmas = .infinity }),
            ("minimumDepth", { $0.minimumDepth = -0.1 }),
            ("minimumSamples", { $0.minimumSamples = 0 }),
            ("sustainUnits", { $0.sustainUnits = -1 }),
            ("minimumTopicUnits", { $0.minimumTopicUnits = 0 }),
            ("minimumTopicDuration", { $0.minimumTopicDuration = .seconds(-1) }),
            ("cooldown", { $0.cooldown = .seconds(-1) }),
            ("recoveryFraction", { $0.recoveryFraction = 1.5 }),
            ("cueBoost", { $0.cueBoost = -1 }),
            ("peakSearchLimit", { $0.peakSearchLimit = 0 }),
        ]
        for (name, mutate) in mutations {
            var config = TopicConfig.default
            mutate(&config)
            #expect(config.validationError?.hasPrefix(name) == true, "\(name): \(config.validationError ?? "nil")")
        }
    }
}
