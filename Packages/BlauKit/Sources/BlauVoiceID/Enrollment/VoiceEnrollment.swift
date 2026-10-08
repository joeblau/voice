import BlauCore
import BlauTelemetry
import Foundation
import Observation
import os

/// Why an enrollment couldn't finish.
public enum VoiceEnrollmentError: Error, Hashable, Sendable {
    /// The voice ID model isn't installed yet or failed to load.
    case modelUnavailable(String)
    /// The microphone couldn't start (permission, a call holding it).
    case microphoneUnavailable(String)
    /// A conversation is using the microphone.
    case microphoneBusy
    /// The microphone stopped before the clip had any audio.
    case microphoneStopped
    /// A top-up needs an enrolled voiceprint and there is none.
    case notEnrolled
    /// A top-up was asked for, but the voiceprint is from another model or
    /// unreadable: enroll again instead.
    case needsReenrollment
    /// The voiceprint couldn't be saved.
    case saveFailed(String)
}

/// The guided voice enrollment (issue #46): asks the plan's prompts one by
/// one, records each clip through the conversation's voice-processing
/// capture, checks it (talking time, level, SNR, clipping, consistency with
/// the other clips), embeds it, and stores the voiceprint.
///
/// ```swift
/// let enrollment = VoiceEnrollment(plan: .enrollment, audio: audio, loadEmbedder: load, store: store,
///                                  deviceModel: VoiceprintDevice.currentModel)
/// await enrollment.start()          // runs until finished, or until a clip is rejected
/// if case .rejected = enrollment.phase { await enrollment.retry() }
/// ```
///
/// The microphone stays on from the first prompt to the last, and each
/// clip stops by itself once it holds enough speech, so the whole capture
/// is about 4 × 6 s; accepted clips move straight on to the next prompt.
/// A rejected clip waits for ``retry()`` so the user can read why.
///
/// Views observe ``phase``, ``currentPrompt`` and ``results``. Every method
/// runs on the main actor; embedding and saving happen off it.
@MainActor
@Observable
public final class VoiceEnrollment {
    /// Where the enrollment is.
    public enum Phase: Equatable, Sendable {
        /// Waiting for ``start()``.
        case notStarted
        /// The microphone and the voice ID model are coming up.
        case preparing
        /// Recording ``currentPrompt``'s clip.
        case recording(EnrollmentMeter)
        /// Checking and embedding the clip.
        case analyzing
        /// The clip was rejected for these reasons; ``retry()`` records the
        /// prompt again. `restarted` when every clip was dropped and the
        /// capture starts over from the first prompt.
        case rejected([EnrollmentClipIssue], restarted: Bool)
        /// Storing the voiceprint.
        case saving
        /// Done: the stored voiceprint.
        case finished(Voiceprint)
        case failed(VoiceEnrollmentError)
        case cancelled

        /// Whether the flow is between ``start()`` and its end.
        public var isActive: Bool {
            switch self {
            case .preparing, .recording, .analyzing, .rejected, .saving: true
            case .notStarted, .finished, .failed, .cancelled: false
            }
        }
    }

    /// The outcome of one recorded clip, for the quality summary.
    public struct ClipResult: Hashable, Sendable {
        public let prompt: EnrollmentPrompt
        public let analysis: EnrollmentClipAnalysis
        /// Match with the other clips (cosine), `nil` before it was
        /// embedded or when there was nothing to compare with.
        public let similarity: Float?
        /// Empty when accepted.
        public let issues: [EnrollmentClipIssue]

        public init(
            prompt: EnrollmentPrompt, analysis: EnrollmentClipAnalysis, similarity: Float?,
            issues: [EnrollmentClipIssue]
        ) {
            self.prompt = prompt
            self.analysis = analysis
            self.similarity = similarity
            self.issues = issues
        }

        public var isAccepted: Bool { issues.isEmpty }
    }

    public let plan: EnrollmentPlan
    public let policy: EnrollmentQualityPolicy

    public private(set) var phase: Phase = .notStarted
    /// The prompt being recorded (or about to be).
    public private(set) var currentPrompt: EnrollmentPrompt?
    /// The latest result per prompt.
    public private(set) var results: [EnrollmentPrompt: ClipResult] = [:]
    /// The newest result.
    public private(set) var lastResult: ClipResult?
    /// How long the enrollment took, from ``start()`` to the saved
    /// voiceprint (reading time and retries included).
    public private(set) var duration: Duration?
    /// The audio recorded across every clip (retries included): the part
    /// of ``duration`` the user spends speaking.
    public private(set) var recordedDuration: Duration = .zero

    /// Clips accepted so far.
    public var acceptedCount: Int { accepted.count }

    // MARK: Dependencies

    @ObservationIgnored private let audio: any EnrollmentAudioSource
    @ObservationIgnored private let loadEmbedder: @Sendable () async throws -> any SpeakerEmbedder
    @ObservationIgnored private let store: any VoiceprintStoring
    @ObservationIgnored private let deviceModel: String
    @ObservationIgnored private let name: String
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private let analyzer: EnrollmentLevelAnalyzer

    // MARK: State

    private struct AcceptedClip {
        let promptIndex: Int
        let embedding: SpeakerEmbedding
    }

    @ObservationIgnored private var embedder: (any SpeakerEmbedder)?
    @ObservationIgnored private var existing: Voiceprint?
    @ObservationIgnored private var accepted: [AcceptedClip] = []
    /// Prompt indices still to record, in order.
    @ObservationIgnored private var pending: [Int] = []
    @ObservationIgnored private var consecutiveMismatches = 0
    @ObservationIgnored private var startedAt: Duration?
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var microphoneOn = false

    /// - Parameters:
    ///   - plan: The prompts: ``EnrollmentPlan/enrollment`` or ``EnrollmentPlan/topUp``.
    ///   - audio: The microphone (``ConversationEnrollmentAudio`` in the app).
    ///   - loadEmbedder: Loads the speaker embedder; called once, while the
    ///     microphone comes up.
    ///   - store: Where the voiceprint goes.
    ///   - deviceModel: This device's model, the key of its enrollment set.
    ///   - name: The profile's display name.
    ///   - policy: The quality bar.
    ///   - clock: Timestamps and the enrollment's duration.
    public init(
        plan: EnrollmentPlan,
        audio: any EnrollmentAudioSource,
        loadEmbedder: @escaping @Sendable () async throws -> any SpeakerEmbedder,
        store: any VoiceprintStoring,
        deviceModel: String,
        name: String = "Me",
        policy: EnrollmentQualityPolicy = .standard,
        analyzer: EnrollmentLevelAnalyzer = EnrollmentLevelAnalyzer(),
        clock: any BlauClock = SystemClock()
    ) {
        self.plan = plan
        self.audio = audio
        self.loadEmbedder = loadEmbedder
        self.store = store
        self.deviceModel = deviceModel
        self.name = name
        self.policy = policy
        self.analyzer = analyzer
        self.clock = clock
    }

    /// The 1-based number of the clip being recorded, for "Clip 2 of 4".
    public var clipNumber: Int { min(plan.prompts.count, accepted.count + 1) }

    // MARK: Controls

    /// Starts the microphone and the model, then records prompts until the
    /// voiceprint is saved, a clip is rejected, or the enrollment fails or
    /// is cancelled. Returns when it gets there.
    public func start() async {
        guard phase == .notStarted else { return }
        startedAt = clock.uptime
        pending = Array(plan.prompts.indices)
        currentPrompt = plan.prompts.first
        await perform { await self.prepareAndRecord() }
    }

    /// After a rejection, records the prompt again (or, after a restart,
    /// the first prompt). Returns like ``start()``.
    public func retry() async {
        guard case .rejected = phase else { return }
        await perform { await self.recordPending() }
    }

    /// Ends the clip being recorded now ("Done speaking"); it is judged on
    /// what was recorded.
    public func finishClip() {
        guard case .recording = phase else { return }
        finishRequested = true
    }

    /// Stops everything and discards the clips. Nothing is stored.
    public func cancel() async {
        guard phase.isActive || phase == .notStarted else { return }
        run?.cancel()
        phase = .cancelled
        await stopMicrophone()
        Log.voiceID.notice("Enrollment cancelled after \(self.accepted.count, privacy: .public) clip(s)")
    }

    private func perform(_ body: @escaping @MainActor () async -> Void) async {
        let task = Task { await body() }
        run = task
        await task.value
        // A cancel that landed while the microphone was still starting.
        if phase == .cancelled { await stopMicrophone() }
    }

    // MARK: Flow

    private func prepareAndRecord() async {
        phase = .preparing
        let load = loadEmbedder
        async let loading: Result<any SpeakerEmbedder, any Error> = {
            do { return .success(try await load()) } catch { return .failure(error) }
        }()
        var failure: VoiceEnrollmentError?
        do {
            try await audio.start()
            microphoneOn = true
        } catch let error as VoiceEnrollmentError {
            failure = error
        } catch {
            failure = .microphoneUnavailable(String(describing: error))
        }
        switch await loading {
        case .success(let loaded): embedder = loaded
        case .failure(let error): failure = failure ?? .modelUnavailable(String(describing: error))
        }
        if failure == nil, plan.purpose == .topUp, let embedder {
            failure = await loadExistingVoiceprint(model: embedder.model)
        }
        if let failure {
            await fail(failure)
            return
        }
        guard !Task.isCancelled else { return }
        await recordPending()
    }

    private func loadExistingVoiceprint(model: SpeakerEmbeddingModelInfo) async -> VoiceEnrollmentError? {
        do {
            switch try await store.status(for: model) {
            case .enrolled(let voiceprint):
                existing = voiceprint
                return nil
            case .notEnrolled: return .notEnrolled
            case .needsReenrollment, .unreadable: return .needsReenrollment
            }
        } catch {
            return .notEnrolled
        }
    }

    /// Records pending prompts until there are none, then saves.
    private func recordPending() async {
        while let index = pending.first {
            guard !Task.isCancelled else { return }
            currentPrompt = plan.prompts[index]
            guard let clip = await recordClip() else { return }
            guard !Task.isCancelled else { return }
            phase = .analyzing
            let outcome = await judge(clip, promptIndex: index)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .accepted:
                continue
            case .rejected(let issues, let restarted):
                phase = .rejected(issues, restarted: restarted)
                return
            case .failed(let error):
                await fail(error)
                return
            }
        }
        // Every prompt has a clip. The first clip was never compared with
        // anything when it was accepted, so check the whole set once more.
        let embeddings = accepted.map(\.embedding)
        if let outlier = EnrollmentConsistency.worstOutlier(embeddings, policy: policy) {
            let clip = accepted.remove(at: outlier.index)
            pending = [clip.promptIndex]
            currentPrompt = plan.prompts[clip.promptIndex]
            let issue = EnrollmentClipIssue.inconsistent(
                similarity: outlier.similarity, minimum: policy.minimumConsistency)
            if let previous = results[plan.prompts[clip.promptIndex]] {
                record(
                    ClipResult(
                        prompt: previous.prompt, analysis: previous.analysis, similarity: outlier.similarity,
                        issues: [issue]))
            }
            Log.voiceID.notice(
                "Enrollment clip \(clip.promptIndex, privacy: .public) doesn't match the others (\(outlier.similarity, privacy: .public)); asking again"
            )
            phase = .rejected([issue], restarted: false)
            return
        }
        await save()
    }

    /// Records one clip; `nil` when cancelled or failed.
    private func recordClip() async -> AudioFrame? {
        finishRequested = false
        var recorder = EnrollmentClipRecorder(plan: plan, analyzer: analyzer)
        phase = .recording(recorder.meter)
        var frameCount = 0
        for await frame in audio.frames() {
            guard !Task.isCancelled else { return nil }
            recorder.append(frame)
            frameCount += 1
            // The meter refreshes every other 20 ms frame.
            if frameCount.isMultiple(of: 2) { phase = .recording(recorder.meter) }
            if recorder.isComplete || finishRequested { break }
        }
        guard !Task.isCancelled else { return nil }
        guard recorder.duration > .zero else {
            await fail(.microphoneStopped)
            return nil
        }
        phase = .recording(recorder.meter)
        recordedDuration += recorder.duration
        return recorder.clip
    }

    private enum Outcome {
        case accepted
        case rejected([EnrollmentClipIssue], restarted: Bool)
        case failed(VoiceEnrollmentError)
    }

    private func judge(_ clip: AudioFrame, promptIndex: Int) async -> Outcome {
        let prompt = plan.prompts[promptIndex]
        let analyzer = analyzer
        let analysis = await Task.detached { analyzer.analyze(clip) }.value
        let audioIssues = policy.audioIssues(analysis, prompt: prompt)
        guard audioIssues.isEmpty else {
            record(ClipResult(prompt: prompt, analysis: analysis, similarity: nil, issues: audioIssues))
            log(prompt, issues: audioIssues)
            return .rejected(audioIssues, restarted: false)
        }
        guard let embedder else { return .failed(.modelUnavailable("not loaded")) }

        let speech = AudioFrame(
            samples: Array(clip.samples[analysis.speechRange]), sampleRate: clip.sampleRate,
            sampleOffset: clip.sampleOffset + Int64(analysis.speechRange.lowerBound))
        let embedding: SpeakerEmbedding
        do {
            embedding = try await embedder.embed(speech)
        } catch let error as SpeakerEmbedderError {
            let issues: [EnrollmentClipIssue] = [.unusable]
            record(ClipResult(prompt: prompt, analysis: analysis, similarity: nil, issues: issues))
            Log.voiceID.error("Enrollment clip couldn't be embedded: \(String(describing: error), privacy: .public)")
            return .rejected(issues, restarted: false)
        } catch is CancellationError {
            return .rejected([], restarted: false)
        } catch {
            return .failed(.modelUnavailable(String(describing: error)))
        }

        let verdict = EnrollmentConsistency.verdict(
            for: embedding, accepted: accepted.map(\.embedding), consecutiveMismatches: consecutiveMismatches,
            voiceprint: existing?.centroid, policy: policy)
        switch verdict {
        case .accept(let similarity):
            accept(embedding, promptIndex: promptIndex, analysis: analysis, similarity: similarity)
            return .accepted
        case .acceptReplacing(let indices, let similarity):
            let dropped = indices.map { accepted[$0].promptIndex }
            for index in indices.sorted(by: >) { accepted.remove(at: index) }
            accept(embedding, promptIndex: promptIndex, analysis: analysis, similarity: similarity)
            // The dropped prompts are asked again, in plan order.
            pending = (pending + dropped).sorted()
            for index in dropped { results[plan.prompts[index]] = nil }
            Log.voiceID.notice(
                "Enrollment dropped \(dropped.count, privacy: .public) earlier clip(s) that didn't match the rest")
            return .accepted
        case .reject(let issue):
            if case .inconsistent = issue { consecutiveMismatches += 1 }
            record(
                ClipResult(prompt: prompt, analysis: analysis, similarity: Self.similarity(of: issue), issues: [issue]))
            log(prompt, issues: [issue])
            return .rejected([issue], restarted: false)
        case .restart(let issue):
            accepted.removeAll()
            results.removeAll()
            consecutiveMismatches = 0
            pending = Array(plan.prompts.indices)
            currentPrompt = plan.prompts.first
            record(
                ClipResult(prompt: prompt, analysis: analysis, similarity: Self.similarity(of: issue), issues: [issue]))
            Log.voiceID.notice("Enrollment clips didn't match each other; starting over")
            return .rejected([issue], restarted: true)
        }
    }

    private func accept(
        _ embedding: SpeakerEmbedding, promptIndex: Int, analysis: EnrollmentClipAnalysis, similarity: Float?
    ) {
        accepted.append(AcceptedClip(promptIndex: promptIndex, embedding: embedding))
        pending.removeAll { $0 == promptIndex }
        consecutiveMismatches = 0
        let prompt = plan.prompts[promptIndex]
        record(ClipResult(prompt: prompt, analysis: analysis, similarity: similarity, issues: []))
        Log.voiceID.notice(
            "Enrollment clip accepted (\(prompt.rawValue, privacy: .public)): \(analysis.speechDuration.timeInterval, format: .fixed(precision: 1), privacy: .public) s speech, SNR \(analysis.signalToNoise, format: .fixed(precision: 1), privacy: .public) dB"
        )
    }

    private func record(_ result: ClipResult) {
        results[result.prompt] = result
        lastResult = result
    }

    private func log(_ prompt: EnrollmentPrompt, issues: [EnrollmentClipIssue]) {
        Log.voiceID.notice(
            "Enrollment clip rejected (\(prompt.rawValue, privacy: .public)): \(String(describing: issues), privacy: .public)"
        )
    }

    private static func similarity(of issue: EnrollmentClipIssue) -> Float? {
        switch issue {
        case .inconsistent(let similarity, _), .doesNotMatchVoiceprint(let similarity, _): similarity
        default: nil
        }
    }

    private func save() async {
        guard let embedder else { return await fail(.modelUnavailable("not loaded")) }
        phase = .saving
        await stopMicrophone()
        let draft = VoiceprintDraft(
            name: name, model: embedder.model, deviceModel: deviceModel,
            embeddings: accepted.sorted { $0.promptIndex < $1.promptIndex }.map(\.embedding), recordedAt: clock.now)
        do {
            let voiceprint =
                switch plan.purpose {
                case .enrollment: try await store.enroll(draft)
                case .topUp: try await store.saveDeviceSet(draft)
                }
            guard !Task.isCancelled else { return }
            let elapsed = startedAt.map { clock.uptime - $0 }
            duration = elapsed
            phase = .finished(voiceprint)
            Log.voiceID.notice(
                "Enrollment (\(self.plan.purpose.rawValue, privacy: .public)) finished in \((elapsed ?? .zero).timeInterval, format: .fixed(precision: 1), privacy: .public) s with \(draft.embeddings.count, privacy: .public) clips"
            )
        } catch VoiceprintStoreError.notEnrolled {
            await fail(.notEnrolled)
        } catch VoiceprintStoreError.modelMismatch {
            await fail(.needsReenrollment)
        } catch {
            await fail(.saveFailed(String(describing: error)))
        }
    }

    private func fail(_ error: VoiceEnrollmentError) async {
        phase = .failed(error)
        await stopMicrophone()
        Log.voiceID.error("Enrollment failed: \(String(describing: error), privacy: .public)")
    }

    private func stopMicrophone() async {
        guard microphoneOn else { return }
        microphoneOn = false
        await audio.stop()
    }
}
