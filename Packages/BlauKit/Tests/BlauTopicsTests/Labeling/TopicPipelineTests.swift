import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTopics

/// Runs a transcript through a `TopicPipeline` and keeps every event.
struct PipelineRun {
    var events: [TopicEvent] = []

    var started: [(boundary: TopicBoundary, label: TopicLabel)] {
        events.compactMap { if case .topicStarted(let boundary, let label) = $0 { (boundary, label) } else { nil } }
    }

    var candidates: [(boundary: TopicBoundary, label: TopicLabel?)] {
        events.compactMap { if case .candidate(let boundary, let label) = $0 { (boundary, label) } else { nil } }
    }

    var rejections: [TopicRejectionReason] {
        events.compactMap { if case .candidateRejected(_, let reason) = $0 { reason } else { nil } }
    }

    static func run(_ units: [TopicUnit], service: TopicLabelingService) async throws -> (PipelineRun, TopicPipeline) {
        let pipeline = TopicPipeline(
            segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics)),
            labeling: service)
        var run = PipelineRun()
        for unit in units {
            run.events += try await pipeline.append(unit)
        }
        run.events += await pipeline.finish()
        return (run, pipeline)
    }
}

@Suite("TopicPipeline")
struct TopicPipelineTests {
    /// A model that agrees with every candidate and titles it after the
    /// first user turn after the boundary.
    static func agreeable(_ source: TopicLabelSource = .foundationModels) -> ScriptedLabeler {
        ScriptedLabeler(source) { request in
            TopicShift(isNewTopic: true, title: "Topic \(request.after.first?.userText.prefix(12) ?? "")", summary: "s")
        }
    }

    @Test func confirmsAndTitlesEveryBoundary() async throws {
        let labeler = Self.agreeable()
        let (run, pipeline) = try await PipelineRun.run(
            ScriptedTranscript.threeTopics.units(), service: .test([labeler]))

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.started.allSatisfy { $0.label.source == .foundationModels })
        #expect(run.candidates.allSatisfy { $0.label != nil })
        #expect(await pipeline.currentTitle == run.started.last?.label.title)

        // Candidates are judged with context and the current title.
        let judged = labeler.requests.filter(\.confirmsBoundary)
        #expect(judged.count == run.candidates.count)
        #expect(judged.allSatisfy { $0.kind == .boundary && !$0.before.isEmpty && !$0.after.isEmpty })
        #expect(judged.allSatisfy { $0.before.count + $0.after.count <= 6 })
        #expect(judged.last?.previousTitle == run.started.first?.label.title)
    }

    @Test func modelVetoesCandidates() async throws {
        let labeler = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Same", summary: "s"))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: .test([labeler]))

        #expect(run.started.isEmpty)
        #expect(!run.candidates.isEmpty)
        #expect(run.rejections.filter { $0 == .vetoed }.count == run.candidates.count)
        #expect(run.candidates.allSatisfy { $0.label == nil })
    }

    @Test func explicitCuesOverrideAVeto() async throws {
        let labeler = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Same", summary: "s"))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.explicitCues.units(), service: .test([labeler]))
        #expect(run.started.map(\.boundary.unitIndex) == [5, 10])
        #expect(run.started.allSatisfy { $0.boundary.hasExplicitCue })
    }

    @Test func cuesCanBeVetoedWhenThePolicySaysSo() async throws {
        let labeler = ScriptedLabeler(
            .foundationModels, answer: TopicShift(isNewTopic: false, title: "Same", summary: "s"))
        let service = TopicLabelingService.test([labeler], policy: TopicLabelingPolicy(explicitCueOverridesVeto: false))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.explicitCues.units(), service: service)
        #expect(run.started.isEmpty)
        #expect(run.rejections.contains(.vetoed))
    }

    @Test func skipsTheConfirmStepWhenSerious() async throws {
        let labeler = Self.agreeable()
        let service = TopicLabelingService.test([labeler], thermal: FixedThermalState(.serious))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)

        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.candidates.allSatisfy { $0.label == nil })
        // One title per confirmed topic and no confirmations.
        #expect(labeler.requests.count == 2)
        #expect(labeler.requests.allSatisfy { !$0.confirmsBoundary })
        #expect(run.started.allSatisfy { $0.label.source == .foundationModels })
    }

    @Test func keywordTitlesWhenCritical() async throws {
        let labeler = Self.agreeable()
        let service = TopicLabelingService.test([labeler], thermal: FixedThermalState(.critical))
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.threeTopics.units(), service: service)
        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.started.allSatisfy { $0.label.source == .keywords })
        #expect(labeler.requests.isEmpty)
    }

    @Test func worksWithoutAnyModel() async throws {
        // A device without Apple Intelligence and without an xAI key.
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let remote = RemoteTopicLabeler(generator: FakeTextGenerator(available: false) { _ in "" })
        let (run, _) = try await PipelineRun.run(
            ScriptedTranscript.threeTopics.units(), service: .test([onDevice, remote]))
        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(run.started.allSatisfy { $0.label.source == .keywords })
    }

    @Test func worksOnXAIWithoutAppleIntelligence() async throws {
        let onDevice = ScriptedLabeler(
            .foundationModels, available: false, answer: TopicShift(isNewTopic: false, title: "x", summary: ""))
        let generator = FakeTextGenerator { _ in #"{"isNewTopic": true, "title": "Grok Title", "summary": "From xAI."}"#
        }
        let (run, _) = try await PipelineRun.run(
            ScriptedTranscript.threeTopics.units(),
            service: .test([onDevice, RemoteTopicLabeler(generator: generator)]))
        #expect(run.started.map(\.boundary.unitIndex) == [6, 12])
        #expect(
            run.started.allSatisfy { $0.label == TopicLabel(title: "Grok Title", summary: "From xAI.", source: .xai) })
        #expect(!generator.requests.isEmpty)
    }

    @Test func singleTopicStaysSilent() async throws {
        let labeler = Self.agreeable()
        let (run, _) = try await PipelineRun.run(ScriptedTranscript.singleTopic.units(), service: .test([labeler]))
        #expect(run.started.isEmpty)
    }

    @Test func labelsTheTopicInProgress() async throws {
        let labeler = Self.agreeable()
        let pipeline = TopicPipeline(
            segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics)),
            labeling: .test([labeler]))
        #expect(await pipeline.labelTopic() == nil)
        for unit in ScriptedTranscript.threeTopics.units().prefix(3) {
            _ = try await pipeline.append(unit)
        }
        let result = try #require(await pipeline.labelTopic())
        #expect(result.label.source == .foundationModels)
        let request = try #require(labeler.requests.last)
        #expect(request.kind == .topic)
        #expect(request.after.count == 3)

        _ = await pipeline.labelTopic(in: 1..<2, previousTitle: "Earlier")
        #expect(labeler.requests.last?.after.count == 1)
        #expect(labeler.requests.last?.previousTitle == "Earlier")
    }

    @Test func manualTitleIsSentWithTheNextBoundary() async throws {
        let labeler = Self.agreeable()
        let pipeline = TopicPipeline(
            segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics)),
            labeling: .test([labeler]))
        await pipeline.setCurrentTitle("Weekend Baking")
        for unit in ScriptedTranscript.threeTopics.units().prefix(9) {
            _ = try await pipeline.append(unit)
        }
        #expect(labeler.requests.first?.previousTitle == "Weekend Baking")
    }

    @Test func aSecondAppendWaitsForTheModel() async throws {
        let units = ScriptedTranscript.threeTopics.units()
        // The unit whose arrival raises the first candidate.
        let probe = TopicPipeline(
            segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics)),
            labeling: .test([Self.agreeable()]))
        var trigger: Int?
        for (index, unit) in units.enumerated() where trigger == nil {
            let events = try await probe.append(unit)
            if events.contains(where: { if case .candidate = $0 { true } else { false } }) { trigger = index }
        }
        let k = try #require(trigger)

        let gate = Gate()
        let labeler = ScriptedLabeler(.foundationModels) { _ in
            await gate.wait()
            return TopicShift(isNewTopic: true, title: "Gated", summary: "s")
        }
        let pipeline = TopicPipeline(
            segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics)),
            labeling: .test([labeler]))
        for unit in units[..<k] {
            _ = try await pipeline.append(unit)
        }
        let first = Task { try await pipeline.append(units[k]) }
        await gate.waitForWaiter()
        let second = Task { try await pipeline.append(units[k + 1]) }
        for _ in 0..<50 { await Task.yield() }
        #expect(await pipeline.segmenter.units.count == k + 1)

        gate.open()
        let firstEvents = try await first.value
        _ = try await second.value
        #expect(
            firstEvents.contains { if case .candidate(_, let label) = $0 { label?.title == "Gated" } else { false } })
        #expect(await pipeline.segmenter.units.count == k + 2)
    }
}

/// Suspends callers until opened.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitForWaiter() async {
        while state.withLock({ $0.waiters.isEmpty }) { await Task.yield() }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
