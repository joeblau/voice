#if canImport(FoundationModels)
    import Foundation
    import Testing

    @testable import BlauTopics

    /// The prewarming seam the benchmark drives on the production labeler.
    /// Nothing here generates or prewarms: making a `LanguageModelSession`
    /// doesn't load the model, so these run without Apple Intelligence.
    @Suite("FoundationModels label benchmark seam")
    struct FoundationModelsLabelBenchmarkGeneratorTests {
        let labeler = FoundationModelsTopicLabeler()

        @Test func aPreparedSessionUsesTheProductionInstructions() throws {
            let request = try #require(TopicLabelRequest.benchmarkRequests.first)
            let prepared = labeler.prepareSession(for: request, prewarm: false)
            #expect(prepared.instructions == TopicLabelPrompt.instructions(for: request))
        }

        @Test func theFirstAttemptRunsInThePreparedSessionOnlyWhenTheInstructionsMatch() throws {
            let request = try #require(TopicLabelRequest.benchmarkRequests.first)
            let prepared = labeler.prepareSession(for: request, prewarm: false)

            let same = prepared.session(for: TopicLabelPrompt.instructions(for: request))
            #expect(same === prepared.session)

            // A title-only request (thermal policy skipped confirmation) has
            // other instructions, so a session prewarmed for a confirming
            // request must not be reused for it.
            var titleOnly = request
            titleOnly.confirmsBoundary = false
            #expect(TopicLabelPrompt.instructions(for: titleOnly) != prepared.instructions)
            #expect(prepared.session(for: TopicLabelPrompt.instructions(for: titleOnly)) == nil)
        }

        @Test func theGeneratorPreparesOneSessionPerRequest() async throws {
            let generator = FoundationModelsLabelBenchmarkGenerator(labeler: labeler)
            let requests = TopicLabelRequest.benchmarkRequests
            let first = try #require(
                await generator.makeSession(for: requests[0], prewarm: false)
                    as? FoundationModelsLabelBenchmarkGenerator.Session)
            let second = try #require(
                await generator.makeSession(for: requests[0], prewarm: false)
                    as? FoundationModelsLabelBenchmarkGenerator.Session)
            #expect(first.request == requests[0])
            #expect(first.prepared.session !== second.prepared.session)
        }
    }
#endif
