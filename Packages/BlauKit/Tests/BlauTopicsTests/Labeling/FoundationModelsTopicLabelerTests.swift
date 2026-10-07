#if canImport(FoundationModels)
    import BlauCore
    import Foundation
    import FoundationModels
    import Testing

    @testable import BlauTopics

    /// The real on-device model over the scripted fixtures. Opt-in, because
    /// it needs Apple Intelligence (an eligible device or Mac with it turned
    /// on and the model downloaded):
    ///
    ///     BLAU_DEVICE_TESTS=1 swift test --filter FoundationModelsTopicLabelerTests
    ///
    /// Prints every title, the confirm / veto decisions and the label
    /// latency (p50, p90) so the numbers in docs/topics.md can be refreshed.
    @Suite(
        "FoundationModelsTopicLabeler (device)",
        .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
        .serialized)
    struct FoundationModelsTopicLabelerTests {
        @Test func labelsEveryScriptedBoundaryInFiveWordsOrFewer() async throws {
            let labeler = FoundationModelsTopicLabeler()
            guard await labeler.isAvailable() else {
                print("Foundation Models unavailable: \(labeler.availability); skipping")
                return
            }
            let service = TopicLabelingService(
                labelers: [labeler], thermal: FixedThermalState(.nominal), timeout: .seconds(30))

            // Warm the model so the first sample isn't a cold load.
            let warmUp = await service.label(.topic(ScriptedTranscript.threeTopics.units()[0..<2]))
            print("warm-up: \(warmUp.latency) (\(warmUp.label.source))")

            var confirmed = 0
            var boundaries = 0
            var vetoedDigressions = 0
            var digressions = 0
            var latencies = LatencyStatistics()
            for transcript in ScriptedTranscript.all {
                let units = transcript.units()
                let starts = [0] + transcript.boundaries
                for (index, start) in transcript.boundaries.enumerated() {
                    let boundary = Self.boundary(at: start, topicStart: starts[index], units: units)
                    let result = await service.label(.boundary(boundary, units: units, previousTitle: nil))
                    latencies.record(result.latency)
                    boundaries += 1
                    if result.isNewTopic { confirmed += 1 }
                    print(
                        "\(transcript.name) boundary \(start): new=\(result.isNewTopic) "
                            + "\"\(result.label.title)\" (\(result.label.source)) in \(result.latency)")
                    #expect(result.label.source == .foundationModels)
                    #expect(TopicTitleFormatter.wordCount(result.label.title) <= 5)
                }
                if let digression = transcript.digression {
                    let boundary = Self.boundary(at: digression.lowerBound, topicStart: 0, units: units)
                    let result = await service.label(.boundary(boundary, units: units, previousTitle: nil))
                    latencies.record(result.latency)
                    digressions += 1
                    if !result.isNewTopic { vetoedDigressions += 1 }
                    print("\(transcript.name) digression at \(digression.lowerBound): new=\(result.isNewTopic)")
                }
                for (start, end) in zip(starts, transcript.boundaries + [transcript.count]) {
                    let result = await service.label(.topic(units[start..<end]))
                    latencies.record(result.latency)
                    print(
                        "\(transcript.name) topic \(start)..<\(end): \"\(result.label.title)\" (\(result.label.source)) in \(result.latency)"
                    )
                    #expect(TopicTitleFormatter.wordCount(result.label.title) <= 5)
                }
            }
            print(
                """
                Foundation Models: confirmed \(confirmed)/\(boundaries) real boundaries, \
                vetoed \(vetoedDigressions)/\(digressions) digressions; \
                label latency p50 \(latencies.p50 ?? .zero), p90 \(latencies.p90 ?? .zero), \
                max \(latencies.maximum ?? .zero) over \(latencies.totalCount) labels
                """)
        }

        @Test func labelsInAPrewarmedSession() async throws {
            let labeler = FoundationModelsTopicLabeler()
            guard await labeler.isAvailable() else { return }
            let request = try #require(TopicLabelRequest.benchmarkRequests.first)
            let prepared = labeler.prepareSession(for: request, prewarm: true)
            try await Task.sleep(for: .seconds(1))
            let shift = try await labeler.label(request, preparedSession: prepared)
            #expect(!shift.title.isEmpty)
            #expect(TopicTitleFormatter.title(shift.title) != nil)
        }

        @Test func respectsTheContextWindowWithAHugeTopic() async throws {
            let labeler = FoundationModelsTopicLabeler()
            guard await labeler.isAvailable() else { return }
            // ~300 exchanges: far beyond 4,096 tokens before trimming.
            let units =
                (0..<5).flatMap { _ in ScriptedTranscript.fourTopics.units() }
                + (0..<12).flatMap { _ in
                    ScriptedTranscript.threeTopics.units()
                }
            let shift = try await labeler.label(.topic(units))
            #expect(!shift.title.isEmpty)
        }

        static func boundary(at index: Int, topicStart: Int, units: [TopicUnit]) -> TopicBoundary {
            TopicBoundary(
                unitIndex: index, unitID: units[index].id, time: units[index].timeRange.start,
                startedAt: units[index].startedAt, closedTopic: topicStart..<index, similarity: 0, depth: 1, score: 1,
                threshold: 0.5, hasExplicitCue: false)
        }
    }
#endif
