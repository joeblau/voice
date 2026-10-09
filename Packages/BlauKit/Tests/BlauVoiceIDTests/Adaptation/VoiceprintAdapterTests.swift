import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

/// The adapter between the gate and the store: level checks, logging and
/// saving at the end of a conversation.
@Suite("Voiceprint adapter")
struct VoiceprintAdapterTests {
    typealias F = AdaptationFixtures

    static let clips = [
        F.unit([0: 1, 5: 0.1], duration: .seconds(5)), F.unit([0: 1, 5: -0.1], duration: .seconds(5)),
    ]
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A store holding a voiceprint enrolled from ``clips``, and that
    /// voiceprint as a conversation loads it.
    static func enrolledStore() async throws -> (InMemoryVoiceprintStore, Voiceprint) {
        let store = InMemoryVoiceprintStore()
        let voiceprint = try await store.enroll(
            VoiceprintDraft(model: F.model, deviceModel: "iPhone18,1", embeddings: clips, recordedAt: start))
        return (store, voiceprint)
    }

    static func adapter(_ voiceprint: Voiceprint, store: (any VoiceprintStoring)?) throws -> VoiceprintAdapter {
        let adaptive = try #require(try AdaptiveVoiceprint(voiceprint: voiceprint, scoring: .cosineCentroid))
        return VoiceprintAdapter(voiceprint: adaptive, store: store, now: { start + 3_600 })
    }

    /// An accepted segment of `embedding` with `audio` (clean synthetic
    /// speech unless given).
    static func segment(
        _ id: Int, _ embedding: SpeakerEmbedding = F.owner, audio: AudioFrame? = nil, seconds: Double = 4
    ) -> ScoredSpeechSegment {
        let thresholds = VoiceIDConfig.calibrated.long
        let score = embedding.cosineSimilarity(to: F.anchor)
        return ScoredSpeechSegment(
            segmentID: id,
            score: SpeakerScore(
                score: score, decision: thresholds.decision(for: score), audioDuration: embedding.audioDuration,
                thresholds: thresholds, embedding: embedding),
            speechDuration: .seconds(seconds),
            audio: audio ?? EnrollmentAudio.clip(.owner, duration: .seconds(seconds)))
    }

    @Test func savesTheAdaptedCentroidWhenTheConversationEnds() async throws {
        let (store, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: store)
        for id in 0..<3 {
            let outcome = await adapter.handle(Self.segment(id))
            guard case .updated = outcome else {
                Issue.record("segment \(id): \(String(describing: outcome))")
                return
            }
        }
        let summary = await adapter.finish()
        #expect(summary.updates == 3)
        #expect(summary.saved)
        #expect(!summary.rolledBack)
        #expect(summary.segments == 3)

        let stored = try #require(await store.status(for: F.model).voiceprint)
        #expect(stored.id == voiceprint.id)
        #expect(stored.centroid.cosineSimilarity(to: adapter.voiceprint.adaptation.centroid) > 0.99999)
        #expect(stored.sets == voiceprint.sets)
        #expect(stored.updatedAt == Self.start + 3_600)
        let drift = try #require(stored.adaptationDrift)
        #expect(abs(drift - summary.drift) < 1e-5)

        // Finishing again changes nothing; later segments are ignored.
        #expect(await adapter.finish() == summary)
        #expect(await adapter.handle(Self.segment(9)) == nil)
    }

    @Test func noisySpeechDoesNotMoveIt() async throws {
        let (_, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: nil)
        let noisy = EnrollmentAudio.clip(
            ScriptedEnrollmentAudio.Voice(noise: 0.03, leadIn: .milliseconds(600)), duration: .seconds(4))
        #expect(EnrollmentClipAnalysis(analyzing: noisy).signalToNoise < 15)
        #expect(await adapter.handle(Self.segment(0, audio: noisy)) == .skipped(.noisy))
        #expect(
            EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(.owner, duration: .seconds(4))).signalToNoise > 30)
        guard case .updated = await adapter.handle(Self.segment(1)) else {
            Issue.record("clean speech should update")
            return
        }
        let summary = await adapter.finish()
        #expect(summary.skips == [.noisy: 1])
        #expect(summary.updates == 1)
        #expect(!summary.saved)  // no store
    }

    @Test func queuedSegmentsAreHandledBeforeFinishing() async throws {
        let (store, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: store)
        for id in 0..<4 { adapter.observe(Self.segment(id)) }
        let summary = await adapter.finish()
        #expect(summary.updates == 4)
        #expect(summary.saved)
        // Segments observed after the end are dropped.
        adapter.observe(Self.segment(10))
        #expect(await adapter.finish().updates == 4)
    }

    @Test func nothingIsSavedWithoutUpdates() async throws {
        let (store, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: store)
        // Accepted, but not by the margin.
        _ = await adapter.handle(Self.segment(0, F.unit([0: 1, 1: 2])))
        let summary = await adapter.finish()
        #expect(summary.updates == 0)
        #expect(summary.skips == [.lowScore: 1])
        #expect(!summary.saved)
        #expect(await store.status(for: F.model).voiceprint == voiceprint)
    }

    @Test func nothingIsSavedAfterARollback() async throws {
        let (store, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: store)
        for id in 0..<10 { _ = await adapter.handle(Self.segment(id, F.unit([0: 1, 1: 0.75]))) }
        var rolledBack = false
        for id in 10..<20 where !rolledBack {
            if case .rolledBack = await adapter.handle(Self.segment(id, F.unit([0: 1, 1: -0.45]))) {
                rolledBack = true
            }
        }
        #expect(rolledBack)
        let summary = await adapter.finish()
        #expect(summary.rolledBack)
        #expect(!summary.saved)
        #expect(summary.updates == 0)
        #expect(await store.status(for: F.model).voiceprint == voiceprint)
    }

    @Test func aVoiceprintReplacedMeanwhileIsNotOverwritten() async throws {
        let (store, voiceprint) = try await Self.enrolledStore()
        let adapter = try Self.adapter(voiceprint, store: store)
        _ = await adapter.handle(Self.segment(0))
        // Re-enrolled on another device during the conversation.
        let other = TestEmbeddings.speaker(3, count: 3)
        let replacement = try await store.enroll(
            VoiceprintDraft(model: F.model, deviceModel: "iPad16,3", embeddings: other, recordedAt: Self.start + 60))
        let summary = await adapter.finish()
        #expect(summary.updates == 1)
        #expect(!summary.saved)
        #expect(await store.status(for: F.model).voiceprint == replacement)
    }
}

/// Saving and undoing adaptation in both stores.
@Suite("Voiceprint store: adaptation")
struct VoiceprintStoreAdaptationTests {
    let model = TestEmbeddings.model
    let owner = TestEmbeddings.speaker(0, count: 4)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func draft(_ embeddings: [SpeakerEmbedding], device: String = "iPhone18,1", at offset: TimeInterval = 0)
        -> VoiceprintDraft
    {
        VoiceprintDraft(model: model, deviceModel: device, embeddings: embeddings, recordedAt: start + offset)
    }

    /// The enrollment centroid moved by cosine distance `drift` towards
    /// axis 9.
    func moved(_ enrollment: SpeakerEmbedding, drift: Float) -> SpeakerEmbedding {
        VoiceprintAdaptation.capped(
            SpeakerEmbedding(
                normalizing: TestEmbeddings.vector(9), modelIdentifier: model.identifier, audioDuration: .zero)!,
            around: enrollment, maximumDrift: drift
        ).embedding
    }

    @Test func savesAnAdaptedCentroidAndKeepsTheSets() async throws {
        for store in try VoiceprintStoreTests.stores() {
            let enrolled = try await store.enroll(draft(owner))
            let enrollment = try #require(enrolled.enrollmentCentroid)
            let adapted = moved(enrollment, drift: 0.05)
            let saved = try await store.saveAdaptedCentroid(
                AdaptedVoiceprintCentroid(
                    voiceprintID: enrolled.id, centroid: adapted, maximumDrift: 0.1, adaptedAt: start + 600))
            let read = try #require(try await store.status(for: model).voiceprint)
            #expect(read == saved)
            #expect(read.centroid.cosineSimilarity(to: adapted) > 0.99999)
            #expect(read.sets == enrolled.sets)
            #expect(read.updatedAt == start + 600)
            #expect(read.createdAt == enrolled.createdAt)
            #expect(abs((read.adaptationDrift ?? 0) - 0.05) < 1e-4)
            // The enrollment centroid is still there to undo it.
            #expect(try #require(read.enrollmentCentroid).cosineSimilarity(to: enrollment) > 0.99999)

            let reset = try await store.resetAdaptation(for: model, at: start + 1_200)
            #expect(reset.centroid.cosineSimilarity(to: enrollment) > 0.99999)
            #expect((reset.adaptationDrift ?? 1) < 1e-5)
            #expect(try await store.status(for: model).voiceprint == reset)
        }
    }

    @Test func refusesAnAdaptationItCannotTrust() async throws {
        for store in try VoiceprintStoreTests.stores() {
            let enrolled = try await store.enroll(draft(owner))
            let enrollment = try #require(enrolled.enrollmentCentroid)
            func save(_ centroid: SpeakerEmbedding, id: UUID = enrolled.id) async throws {
                try await store.saveAdaptedCentroid(
                    AdaptedVoiceprintCentroid(voiceprintID: id, centroid: centroid, maximumDrift: 0.1, adaptedAt: start)
                )
            }
            // Past the cap.
            await #expect(throws: VoiceprintStoreError.self) { try await save(moved(enrollment, drift: 0.3)) }
            // Another voiceprint's.
            await #expect(throws: VoiceprintStoreError.voiceprintReplaced) {
                try await save(moved(enrollment, drift: 0.05), id: UUID())
            }
            // Another model's.
            let foreign = SpeakerEmbedding(
                normalizing: enrollment.vector, modelIdentifier: "other-model", audioDuration: .zero)!
            await #expect(throws: VoiceprintStoreError.modelMismatch(stored: model.identifier, draft: "other-model")) {
                try await save(foreign)
            }
            // Nothing changed.
            #expect(try await store.status(for: model).voiceprint == enrolled)

            try await store.deleteVoiceprint()
            await #expect(throws: VoiceprintStoreError.notEnrolled) { try await save(moved(enrollment, drift: 0.05)) }
            await #expect(throws: VoiceprintStoreError.notEnrolled) {
                try await store.resetAdaptation(for: model, at: start)
            }
        }
    }

    /// Another device's top-up changes the enrollment sets: the centroid is
    /// recomputed from every clip, which also undoes adaptation.
    @Test func aTopUpStartsAdaptationOver() async throws {
        for store in try VoiceprintStoreTests.stores() {
            let enrolled = try await store.enroll(draft(owner))
            let enrollment = try #require(enrolled.enrollmentCentroid)
            try await store.saveAdaptedCentroid(
                AdaptedVoiceprintCentroid(
                    voiceprintID: enrolled.id, centroid: moved(enrollment, drift: 0.08), maximumDrift: 0.1,
                    adaptedAt: start + 10))
            let topped = try await store.saveDeviceSet(
                draft(TestEmbeddings.speaker(0, count: 3), device: "iPad16,3", at: 20))
            #expect((topped.adaptationDrift ?? 1) < 1e-5)
        }
    }
}

/// The gate hands its accepted segments to adaptation.
@Suite("Verification gate: adaptation")
struct VerificationGateAdaptationTests {
    typealias Voice = ScriptedEnrollmentAudio.Voice

    @Test func acceptedSegmentsReachTheObserver() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: try await SpeakerVerifierTests.ownerVoiceprint(embedder),
            gauges: PerformanceGauges())
        let seen = Mutex<[ScoredSpeechSegment]>([])
        let gate = VerificationGate(
            verifier: verifier, onScoredSpeech: { segment in seen.withLock { $0.append(segment) } })

        let scene = GateScenario(lines: [
            VerificationGateScenarioTests.line(
                "Owner", VerificationGateScenarioTests.owner, from: 0, to: 4, isOwner: true),
            VerificationGateScenarioTests.line(
                "TV", VerificationGateScenarioTests.otherPerson, from: 5, to: 9, isOwner: false),
            VerificationGateScenarioTests.line(
                "Short", VerificationGateScenarioTests.owner, from: 9.5, to: 10.2, isOwner: true),
        ])
        _ = await scene.run(through: gate)

        let segments = seen.withLock { $0 }
        #expect(segments.map(\.segmentID) == [0])
        let segment = try #require(segments.first)
        #expect(segment.score.decision == .accept)
        #expect(segment.score.embedding != nil)
        #expect(segment.speechDuration == .seconds(4))
        // The speech only: not VAD's hangover.
        #expect(segment.audio.sampleCount == 64_000)
        #expect(segment.audio.sampleOffset == 0)
    }

    /// The whole path: the gate's accepted speech moves the voiceprint the
    /// verifier scores against, and the end of the conversation saves it.
    @Test func aConversationAdaptsAndSavesTheVoiceprint() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let clips = [6, 7, 8].map { EnrollmentAudio.clip(.owner, duration: .seconds(Double($0))) }
        let store = InMemoryVoiceprintStore()
        let enrolled = try await store.enroll(
            VoiceprintDraft(
                model: .weSpeakerResNet34LM, deviceModel: "Mac", embeddings: try await embedder.embed(clips),
                recordedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: enrolled, adaptation: .standard, gauges: PerformanceGauges())
        let adapter = VoiceprintAdapter(voiceprint: try #require(verifier.adaptive), store: store)
        let gate = VerificationGate(verifier: verifier, onScoredSpeech: { adapter.observe($0) })

        let owner = VerificationGateScenarioTests.owner
        let scene = GateScenario(lines: [
            VerificationGateScenarioTests.line("One", owner, from: 0, to: 4.5, isOwner: true),
            VerificationGateScenarioTests.line("Two", owner, from: 6, to: 11, isOwner: true),
            VerificationGateScenarioTests.line(
                "Other", VerificationGateScenarioTests.otherPerson, from: 12, to: 16, isOwner: false),
            VerificationGateScenarioTests.line("Three", owner, from: 17, to: 21.5, isOwner: true),
        ])
        let (sent, _) = await scene.run(through: gate)
        #expect(sent == ["One", "Two", "Three"])

        let summary = await adapter.finish()
        #expect(summary.updates == 3)
        #expect(summary.saved)
        let stored = try #require(await store.status(for: .weSpeakerResNet34LM).voiceprint)
        #expect(stored.centroid.cosineSimilarity(to: try #require(verifier.adaptive).adaptation.centroid) > 0.99999)
        #expect((stored.adaptationDrift ?? 0) > 0)
        #expect((stored.adaptationDrift ?? 1) <= VoiceprintAdaptationPolicy.standard.maximumDrift + 1e-4)
    }
}
