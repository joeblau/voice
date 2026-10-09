import Synchronization

/// The voiceprint a conversation scores against, adapting as it goes
/// (#49): the live ``VoiceprintAdaptation`` and the ``VoiceprintMatcher``
/// over its current centroid, shared by the ``SpeakerVerifier`` (which
/// reads the matcher for every score) and the ``VoiceprintAdapter`` (which
/// feeds it the gate's accepted segments).
///
/// An update applies from the next score on. Rebuilding the matcher is a
/// few dot products (one cohort pass under AS-norm), done only when the
/// centroid moves.
public final class AdaptiveVoiceprint: Sendable {
    private struct State: Sendable {
        var adaptation: VoiceprintAdaptation
        var voiceprint: Voiceprint
        var matcher: VoiceprintMatcher
    }

    public let scoring: VoiceIDScoring
    private let cohort: SpeakerCohort?
    private let state: Mutex<State>

    /// - Parameters:
    ///   - voiceprint: The stored voiceprint. Its sets give the enrollment
    ///     centroid, the anchor of the drift cap.
    ///   - scoring: The gate's scoring method.
    ///   - cohort: The impostor cohort, for AS-norm.
    /// - Returns: `nil` when the voiceprint has no readable enrollment sets:
    ///   without the enrollment centroid there is nothing to cap the drift
    ///   against, so the voiceprint isn't adapted.
    /// - Throws: `VoiceprintScorer.Error` when the scoring method can't run.
    public init?(
        voiceprint: Voiceprint, scoring: VoiceIDScoring, cohort: SpeakerCohort? = nil,
        policy: VoiceprintAdaptationPolicy = .standard
    ) throws(VoiceprintScorer.Error) {
        guard let enrollmentCentroid = voiceprint.enrollmentCentroid else { return nil }
        let adaptation = try VoiceprintAdaptation(
            enrollmentCentroid: enrollmentCentroid, centroid: voiceprint.centroid, scoring: scoring, cohort: cohort,
            policy: policy)
        let current = voiceprint.withCentroid(adaptation.centroid)
        let matcher = try VoiceprintMatcher(
            voiceprint: current, scoring: scoring, cohort: cohort, adaptedCentroidPenalty: policy.adaptedCentroidPenalty
        )
        self.scoring = scoring
        self.cohort = cohort
        self.state = Mutex(State(adaptation: adaptation, voiceprint: current, matcher: matcher))
    }

    /// What to score against now.
    public var matcher: VoiceprintMatcher { state.withLock { $0.matcher } }

    /// The voiceprint with the adapted centroid.
    public var voiceprint: Voiceprint { state.withLock { $0.voiceprint } }

    /// The adaptation so far: the centroid, the snapshot, the counters.
    public var adaptation: VoiceprintAdaptation { state.withLock { $0.adaptation } }

    /// Offers one accepted segment (see ``VoiceprintAdaptation/consider(_:)``).
    @discardableResult
    public func consider(_ evidence: VoiceprintAdaptationEvidence) -> VoiceprintAdaptation.Outcome {
        state.withLock { state in
            let before = state.adaptation.centroid
            let outcome = state.adaptation.consider(evidence)
            if state.adaptation.centroid != before { refresh(&state) }
            return outcome
        }
    }

    /// Undoes the conversation's updates and stops adapting until the next
    /// conversation.
    public func rollback() {
        state.withLock { state in
            state.adaptation.rollback()
            refresh(&state)
        }
    }

    private func refresh(_ state: inout State) {
        let voiceprint = state.voiceprint.withCentroid(state.adaptation.centroid)
        // The same voiceprint, scoring method and cohort built the first
        // matcher, so this can only fail on a degenerate centroid, which
        // `VoiceprintAdaptation` never produces. Keep the old one if it does.
        guard
            let matcher = try? VoiceprintMatcher(
                voiceprint: voiceprint, scoring: scoring, cohort: cohort,
                adaptedCentroidPenalty: state.adaptation.policy.adaptedCentroidPenalty)
        else {
            return
        }
        state.voiceprint = voiceprint
        state.matcher = matcher
    }
}
