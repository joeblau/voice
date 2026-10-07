import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTopics

@Suite("TopicLabelingService")
struct TopicLabelingServiceTests {
    private let units = ScriptedTranscript.threeTopics.units()

    private var boundaryRequest: TopicLabelRequest {
        TopicLabelRequest(kind: .boundary, before: Array(units[3..<6]), after: Array(units[6..<9]))
    }

    @Test func usesTheFirstAvailableLabeler() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Bread", summary: "s"))
        let remote = ScriptedLabeler(.xai, answer: TopicShift(isNewTopic: true, title: "Remote", summary: "s"))
        let service = TopicLabelingService.test([onDevice, remote])

        let result = await service.label(boundaryRequest)
        #expect(result.label.source == .foundationModels)
        #expect(result.label.title == "Bread")
        #expect(!result.isNewTopic)
        #expect(result.wasJudged)
        #expect(remote.requests.isEmpty)
    }

    @Test func fallsBackToXAIWithoutAppleIntelligence() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: true, title: "x", summary: ""))
        let remote = ScriptedLabeler(
            .xai, answer: TopicShift(isNewTopic: true, title: "marathon training", summary: "running."))
        let service = TopicLabelingService.test([onDevice, remote])

        let result = await service.label(boundaryRequest)
        #expect(result.label == TopicLabel(title: "Marathon Training", summary: "Running.", source: .xai))
        #expect(onDevice.requests.isEmpty)
    }

    @Test func fallsBackToKeywordsWhenNoModelCanRun() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let remote = ScriptedLabeler(
            .xai, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let service = TopicLabelingService.test([onDevice, remote])

        let result = await service.label(boundaryRequest)
        #expect(result.label.source == .keywords)
        #expect(result.isNewTopic)
        #expect(!result.wasJudged)
        #expect(TopicTitleFormatter.wordCount(result.label.title) <= 5)
        #expect(!result.label.summary.isEmpty)
    }

    @Test func movesOnWhenALabelerFails() async {
        let onDevice = ScriptedLabeler(.foundationModels) { _ in throw TopicLabelerError.contextWindowExceeded }
        let remote = ScriptedLabeler(.xai, answer: TopicShift(isNewTopic: true, title: "Remote", summary: "s"))
        let result = await TopicLabelingService.test([onDevice, remote]).label(boundaryRequest)
        #expect(result.label.source == .xai)
        #expect(onDevice.requests.count == 1)
    }

    @Test func movesOnWhenATitleIsUnusable() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: true, title: " \"\" ", summary: "s"))
        let result = await TopicLabelingService.test([onDevice]).label(boundaryRequest)
        #expect(result.label.source == .keywords)
    }

    @Test func missingSummaryFallsBackToKeywords() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: true, title: "Marathon", summary: ""))
        let result = await TopicLabelingService.test([onDevice]).label(boundaryRequest)
        #expect(result.label.title == "Marathon")
        #expect(result.label.summary.hasPrefix("A conversation about "))
    }

    @Test(arguments: unrulyTitles)
    func normalizesEveryModelTitle(_ raw: String) async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: true, title: raw, summary: raw))
        let result = await TopicLabelingService.test([onDevice]).label(boundaryRequest)
        #expect(TopicTitleFormatter.wordCount(result.label.title) <= TopicTitleFormatter.maximumWords)
        #expect(result.label.title == TopicTitleFormatter.title(raw))
    }

    @Test func topicRequestsAreNeverJudged() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Bread", summary: "s"))
        let result = await TopicLabelingService.test([onDevice]).label(.topic(units[0..<6]))
        #expect(result.isNewTopic)
        #expect(!result.wasJudged)
    }

    @Test func timesOutASlowLabeler() async {
        let clock = ManualClock()
        let slow = ScriptedLabeler(.foundationModels) { _ in
            // Ignores cancellation, like a model mid-inference.
            try? await Task.sleep(for: .seconds(3600))
            return TopicShift(isNewTopic: false, title: "Late", summary: "")
        }
        let remote = ScriptedLabeler(.xai, answer: TopicShift(isNewTopic: true, title: "On Time", summary: "s"))
        let service = TopicLabelingService.test([slow, remote], clock: clock, timeout: .seconds(5))

        async let result = service.label(boundaryRequest)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(5))
        #expect(await result.label.title == "On Time")
        #expect(await result.latency == .seconds(5))
    }

    @Test func recordsLatencyPerSource() async {
        let clock = ManualClock()
        let onDevice = ScriptedLabeler(.foundationModels) { _ in
            try await clock.sleep(for: .milliseconds(400))
            return TopicShift(isNewTopic: true, title: "Title", summary: "s")
        }
        let service = TopicLabelingService.test([onDevice], clock: clock)
        for _ in 0..<3 {
            async let result = service.label(boundaryRequest)
            await clock.waitForSleepers(count: 2)  // the labeler and the deadline
            clock.advance(by: .milliseconds(400))
            #expect(await result.latency == .milliseconds(400))
        }
        let stats = await service.latency(for: .foundationModels)
        #expect(stats.totalCount == 3)
        #expect(stats.p50 == .milliseconds(400))
        #expect(await service.overallLatency.totalCount == 3)
        #expect(await service.latency(for: .xai).isEmpty)
    }

    @Test func emitsTheLabelSignpost() async {
        let backend = RecordingSignpostBackend()
        let service = TopicLabelingService.test(
            [ScriptedLabeler(.foundationModels, answer: TopicShift(isNewTopic: true, title: "T", summary: "s"))],
            signposter: Signposter(category: .topics, backend: backend))
        _ = await service.label(boundaryRequest)
        #expect(backend.completedIntervals == ["topics.label"])
        #expect(backend.openIntervals.isEmpty)
    }

    // MARK: Thermal policy

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func confirmsWhenCool(_ state: ProcessInfo.ThermalState) async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "T", summary: "s"))
        let service = TopicLabelingService.test([onDevice], thermal: FixedThermalState(state))
        #expect(await service.mode == .full)
        let result = await service.label(boundaryRequest)
        #expect(result.wasJudged)
        #expect(onDevice.requests.first?.confirmsBoundary == true)
    }

    @Test func skipsConfirmationWhenSerious() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "T", summary: "s"))
        let service = TopicLabelingService.test([onDevice], thermal: FixedThermalState(.serious))
        #expect(await service.mode == .skipConfirmation)
        let result = await service.label(boundaryRequest)
        #expect(result.isNewTopic)
        #expect(!result.wasJudged)
        #expect(result.label.source == .foundationModels)
        #expect(onDevice.requests.first?.confirmsBoundary == false)
    }

    @Test func onlyKeywordsWhenCritical() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "T", summary: "s"))
        let service = TopicLabelingService.test([onDevice], thermal: FixedThermalState(.critical))
        let result = await service.label(boundaryRequest)
        #expect(result.label.source == .keywords)
        #expect(onDevice.requests.isEmpty)
    }

    @Test func policyMapsThermalStates() {
        let policy = TopicLabelingPolicy.default
        #expect(policy.mode(for: .nominal) == .full)
        #expect(policy.mode(for: .fair) == .full)
        #expect(policy.mode(for: .serious) == .skipConfirmation)
        #expect(policy.mode(for: .critical) == .keywordsOnly)
        let strict = TopicLabelingPolicy(skipConfirmationAt: .fair, keywordsOnlyAt: .serious)
        #expect(strict.mode(for: .fair) == .skipConfirmation)
        #expect(strict.mode(for: .serious) == .keywordsOnly)
    }

    // The standard chain is built with a scripted on-device labeler, so these
    // tests never run the real model. Real inference is only exercised by the
    // BLAU_DEVICE_TESTS-gated tests in FoundationModelsTopicLabelerTests.

    private static let xaiReply = #"{"isNewTopic": true, "title": "Grok Title", "summary": "From xAI."}"#

    @Test func standardChainPrefersTheOnDeviceLabeler() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "On Device", summary: "s"))
        let generator = FakeTextGenerator { _ in Self.xaiReply }
        let service = TopicLabelingService.standard(
            textGenerator: generator, onDevice: onDevice, thermal: FixedThermalState(.nominal))

        let result = await service.label(boundaryRequest)
        #expect(result.label.source == .foundationModels)
        #expect(result.label.title == "On Device")
        #expect(onDevice.requests.count == 1)
        #expect(generator.requests.isEmpty)
    }

    @Test func standardChainFallsBackToXAIWhenOnDeviceIsUnavailable() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let generator = FakeTextGenerator { _ in Self.xaiReply }
        let service = TopicLabelingService.standard(
            textGenerator: generator, onDevice: onDevice, thermal: FixedThermalState(.nominal))

        let result = await service.label(boundaryRequest)
        #expect(result.label == TopicLabel(title: "Grok Title", summary: "From xAI.", source: .xai))
        #expect(onDevice.requests.isEmpty)
        #expect(generator.requests.count == 1)
    }

    @Test func standardChainEndsWithKeywords() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let generator = FakeTextGenerator(available: false) { _ in Self.xaiReply }
        let service = TopicLabelingService.standard(
            textGenerator: generator, onDevice: onDevice, thermal: FixedThermalState(.nominal))

        let result = await service.label(.topic(units[0..<1]))
        #expect(result.label.source == .keywords)
        #expect(!result.label.title.isEmpty)
        #expect(onDevice.requests.isEmpty)
        #expect(generator.requests.isEmpty)
    }

    @Test func standardChainWithoutModelsUsesKeywords() async {
        let service = TopicLabelingService.standard(
            textGenerator: nil, onDevice: nil, thermal: FixedThermalState(.nominal))
        let result = await service.label(boundaryRequest)
        #expect(result.label.source == .keywords)
    }

    @Test func defaultOnDeviceLabelerIsFoundationModels() {
        // Only builds the labeler; no inference runs.
        #if canImport(FoundationModels)
            #expect(TopicLabelingService.defaultOnDeviceLabeler()?.source == .foundationModels)
        #else
            #expect(TopicLabelingService.defaultOnDeviceLabeler() == nil)
        #endif
    }
}

@Suite("LatencyStatistics")
struct LatencyStatisticsTests {
    @Test func percentilesByNearestRank() {
        var stats = LatencyStatistics()
        #expect(stats.p50 == nil)
        for ms in [500, 100, 300, 200, 400] {
            stats.record(.milliseconds(ms))
        }
        #expect(stats.p50 == .milliseconds(300))
        #expect(stats.p90 == .milliseconds(500))
        #expect(stats.percentile(0) == .milliseconds(100))
        #expect(stats.maximum == .milliseconds(500))
    }

    @Test func keepsABoundedWindow() {
        var stats = LatencyStatistics(capacity: 3)
        for ms in 1...10 {
            stats.record(.milliseconds(ms))
        }
        #expect(stats.samples == [.milliseconds(8), .milliseconds(9), .milliseconds(10)])
        #expect(stats.totalCount == 10)
    }
}

@Suite("withDeadline")
struct DeadlineTests {
    @Test func returnsTheResultBeforeTheDeadline() async throws {
        let value = try await withDeadline(.seconds(1), clock: ManualClock()) { 42 }
        #expect(value == 42)
    }

    @Test func passesErrorsThrough() async {
        await #expect(throws: FakeLabelerError.self) {
            try await withDeadline(.seconds(1), clock: ManualClock()) { () async throws -> Int in
                throw FakeLabelerError()
            }
        }
    }

    @Test func throwsTimedOutAtTheDeadline() async {
        let clock = ManualClock()
        let task = Task {
            try await withDeadline(.seconds(2), clock: clock) { () async throws -> Int in
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(2))
        await #expect(throws: TopicLabelerError.timedOut) { try await task.value }
    }

    @Test func cancellationStopsWaiting() async {
        let clock = ManualClock()
        let task = Task {
            try await withDeadline(.seconds(2), clock: clock) { () async throws -> Int in
                try? await Task.sleep(for: .seconds(3600))
                return 1
            }
        }
        await clock.waitForSleepers()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
