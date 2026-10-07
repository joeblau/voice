import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTopics

/// Topic labeling under the thermal and power policy (#75): at `reduced`
/// only strong candidates go to the model, at `minimal` none do.
@Suite("Topic labeling and the performance level")
struct TopicPerformanceLevelTests {
    static func boundary(score: Double, threshold: Double = 0.2) -> TopicBoundary {
        TopicBoundary(
            unitIndex: 4, unitID: UUID(), time: .seconds(90), startedAt: Date(timeIntervalSince1970: 0),
            closedTopic: 0..<4, similarity: 0.1, depth: score, score: score, threshold: threshold,
            hasExplicitCue: false)
    }

    static var request: TopicLabelRequest {
        let units = ScriptedTranscript.threeTopics.units()
        return TopicLabelRequest(kind: .boundary, before: Array(units[3..<6]), after: Array(units[6..<9]))
    }

    // MARK: Policy

    @Test func levelsMapToModes() {
        let policy = TopicLabelingPolicy.default
        #expect(policy.mode(for: PerformanceLevel.normal) == .full)
        #expect(policy.mode(for: PerformanceLevel.reduced) == .confirmStrongCandidates)
        #expect(policy.mode(for: PerformanceLevel.minimal) == .skipConfirmation)
    }

    @Test func theStricterOfThermalStateAndLevelWins() {
        let policy = TopicLabelingPolicy.default
        #expect(policy.mode(for: .nominal, level: .reduced) == .confirmStrongCandidates)
        #expect(policy.mode(for: .serious, level: .reduced) == .skipConfirmation)
        #expect(policy.mode(for: .critical, level: .normal) == .keywordsOnly)
        #expect(policy.mode(for: .fair, level: .minimal) == .skipConfirmation)
        #expect(
            TopicLabelingMode.allCases.sorted() == [.full, .confirmStrongCandidates, .skipConfirmation, .keywordsOnly])
    }

    @Test func strongCandidatesClearTheThresholdByTheRatio() {
        let policy = TopicLabelingPolicy.default
        #expect(policy.strongCandidateRatio == 1.5)
        #expect(!policy.isStrong(Self.boundary(score: 0.25)))
        #expect(policy.isStrong(Self.boundary(score: 0.31)))
        #expect(policy.isStrong(Self.boundary(score: 0.6)))

        #expect(policy.confirms(Self.boundary(score: 0.25), in: .full))
        #expect(!policy.confirms(Self.boundary(score: 0.25), in: .confirmStrongCandidates))
        #expect(policy.confirms(Self.boundary(score: 0.6), in: .confirmStrongCandidates))
        #expect(!policy.confirms(Self.boundary(score: 0.6), in: .skipConfirmation))
        #expect(!policy.confirms(Self.boundary(score: 0.6), in: .keywordsOnly))
    }

    // MARK: Service

    @Test func atReducedTheServiceStillJudgesWhatTheCallerSends() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Same", summary: "s"))
        let service = TopicLabelingService.test([onDevice], performance: FixedPerformanceLevel(.reduced))
        #expect(await service.mode == .confirmStrongCandidates)
        let result = await service.label(Self.request)
        #expect(result.wasJudged)
        #expect(!result.isNewTopic)
        #expect(onDevice.requests.first?.confirmsBoundary == true)
    }

    @Test func atMinimalTheServiceOnlyTitles() async {
        let onDevice = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Same", summary: "s"))
        let service = TopicLabelingService.test([onDevice], performance: FixedPerformanceLevel(.minimal))
        #expect(await service.mode == .skipConfirmation)
        let result = await service.label(Self.request)
        #expect(!result.wasJudged)
        #expect(result.label.source == .foundationModels)
        #expect(onDevice.requests.first?.confirmsBoundary == false)
    }

    @Test func theModeFollowsTheLevelLive() async {
        let level = ManualPerformanceLevel(.normal)
        let service = TopicLabelingService.test([], performance: level)
        #expect(await service.mode == .full)
        level.set(.reduced)
        #expect(await service.mode == .confirmStrongCandidates)
        level.set(.normal)
        #expect(await service.mode == .full)
    }

    // MARK: Pipeline

    @Test func atReducedOnlyStrongCandidatesAreSentToTheModel() async throws {
        let labeler = TopicPipelineTests.agreeable()
        let policy = TopicLabelingPolicy.default
        let service = TopicLabelingService.test(
            [labeler], policy: policy, performance: FixedPerformanceLevel(.reduced))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12], "the same topics as at normal")
        #expect(!run.candidates.isEmpty)
        for candidate in run.candidates {
            #expect((candidate.label != nil) == policy.isStrong(candidate.boundary))
        }
        let strong = run.candidates.filter { policy.isStrong($0.boundary) }.count
        #expect(labeler.requests.filter(\.confirmsBoundary).count == strong)
        #expect(run.started.allSatisfy { $0.label.source == .foundationModels })
    }

    @Test func atReducedEveryCandidateIsWeakWithAnUnreachableRatio() async throws {
        let labeler = TopicPipelineTests.agreeable()
        let service = TopicLabelingService.test(
            [labeler], policy: TopicLabelingPolicy(strongCandidateRatio: .infinity),
            performance: FixedPerformanceLevel(.reduced))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.candidates.allSatisfy { $0.label == nil })
        #expect(labeler.requests.count == 2, "one title per topic, no confirmations")
        #expect(labeler.requests.allSatisfy { !$0.confirmsBoundary })
    }

    @Test func atReducedEveryCandidateIsStrongWithARatioOfZero() async throws {
        let labeler = TopicPipelineTests.agreeable()
        let service = TopicLabelingService.test(
            [labeler], policy: TopicLabelingPolicy(strongCandidateRatio: 0),
            performance: FixedPerformanceLevel(.reduced))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.candidates.allSatisfy { $0.label != nil })
        #expect(labeler.requests.filter(\.confirmsBoundary).count == run.candidates.count)
    }

    @Test func atMinimalNoCandidateIsSentToTheModel() async throws {
        let labeler = TopicPipelineTests.agreeable()
        let service = TopicLabelingService.test([labeler], performance: FixedPerformanceLevel(.minimal))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.candidates.allSatisfy { $0.label == nil })
        #expect(labeler.requests.allSatisfy { !$0.confirmsBoundary })
    }
}
