/// Decides whether a new enrollment clip sounds like the clips already
/// accepted: the "consistency" part of the quality meter.
///
/// A voiceprint built from clips of two different people (someone else
/// answered a prompt, a TV took over) would accept both of them, so every
/// clip must match the others at least as well as the gate's accept
/// threshold. The difficulty is knowing which clip is wrong:
///
/// 1. With nothing accepted yet the clip is accepted (a top-up clip must
///    still match the synced voiceprint).
/// 2. A clip that matches the mean of the accepted clips is accepted.
/// 3. The first mismatch rejects the new clip: it is the likelier culprit.
/// 4. A second mismatch in a row suggests an earlier clip is the odd one
///    out. With at least two accepted clips, each clip is compared with the
///    mean of all the others (leave one out). Accepted clips that fall below
///    the limit are dropped (their prompts are asked again), and the new
///    clip is kept if it matches what remains; otherwise it is rejected. With a single accepted clip there is no
///    telling which of the two is wrong, so the capture starts over.
///
/// Before the voiceprint is saved, ``worstOutlier(_:policy:)`` checks the
/// finished set the same way, which also covers the first clip (never
/// compared with anything when it was accepted).
public enum EnrollmentConsistency {
    /// What to do with a new clip.
    public enum Verdict: Hashable, Sendable {
        /// Keep it. `similarity` is its match with the accepted clips, `nil`
        /// when there was nothing to compare with.
        case accept(similarity: Float?)
        /// Keep it, and drop the accepted clips at `indices` (positions in
        /// the `accepted` array passed in) so their prompts are asked again.
        case acceptReplacing(indices: [Int], similarity: Float)
        /// Reject it; ask the same prompt again.
        case reject(EnrollmentClipIssue)
        /// Drop every clip and start the capture over.
        case restart(EnrollmentClipIssue)
    }

    /// The verdict on `candidate`.
    ///
    /// - Parameters:
    ///   - candidate: The new clip's embedding.
    ///   - accepted: The clips accepted so far, in order.
    ///   - consecutiveMismatches: How many clips in a row (just before this
    ///     one) were rejected as inconsistent.
    ///   - voiceprint: For a top-up, the synced voiceprint's centroid.
    ///   - policy: The similarity limits.
    public static func verdict(
        for candidate: SpeakerEmbedding,
        accepted: [SpeakerEmbedding],
        consecutiveMismatches: Int,
        voiceprint: SpeakerEmbedding? = nil,
        policy: EnrollmentQualityPolicy = .standard
    ) -> Verdict {
        if let voiceprint {
            let match = candidate.cosineSimilarity(to: voiceprint)
            if match < policy.minimumVoiceprintMatch {
                return .reject(.doesNotMatchVoiceprint(similarity: match, minimum: policy.minimumVoiceprintMatch))
            }
        }
        guard let mean = SpeakerEmbedding.mean(of: accepted) else { return .accept(similarity: nil) }
        let similarity = candidate.cosineSimilarity(to: mean)
        let minimum = policy.minimumConsistency
        if similarity >= minimum { return .accept(similarity: similarity) }
        let issue = EnrollmentClipIssue.inconsistent(similarity: similarity, minimum: minimum)
        guard consecutiveMismatches > 0 else { return .reject(issue) }
        guard accepted.count >= 2 else { return .restart(issue) }

        // Which accepted clips don't fit the whole set, the new clip
        // included?
        let scores = leaveOneOut(accepted + [candidate])
        let dropped = accepted.indices.filter { scores[$0] < minimum }
        guard !dropped.isEmpty else { return .reject(issue) }
        // Keep at least one earlier clip; dropping all of them is a restart.
        guard dropped.count < accepted.count else { return .restart(issue) }
        let kept = accepted.indices.filter { !dropped.contains($0) }.map { accepted[$0] }
        guard let keptMean = SpeakerEmbedding.mean(of: kept) else { return .reject(issue) }
        let keptSimilarity = candidate.cosineSimilarity(to: keptMean)
        guard keptSimilarity >= minimum else { return .reject(issue) }
        return .acceptReplacing(indices: dropped, similarity: keptSimilarity)
    }

    /// Each embedding's cosine similarity with the mean of all the others.
    /// Fewer than two embeddings have nothing to compare with: `[1]` or `[]`.
    public static func leaveOneOut(_ embeddings: [SpeakerEmbedding]) -> [Float] {
        guard embeddings.count >= 2 else { return embeddings.map { _ in 1 } }
        return embeddings.indices.map { index in
            var others = embeddings
            others.remove(at: index)
            guard let mean = SpeakerEmbedding.mean(of: others) else { return -1 }
            return embeddings[index].cosineSimilarity(to: mean)
        }
    }

    /// The index of the clip that fits the rest worst, if it falls below the
    /// policy's consistency limit; `nil` when the set is consistent.
    public static func worstOutlier(
        _ embeddings: [SpeakerEmbedding], policy: EnrollmentQualityPolicy = .standard
    ) -> (index: Int, similarity: Float)? {
        guard embeddings.count >= 2 else { return nil }
        let scores = leaveOneOut(embeddings)
        guard let worst = scores.indices.min(by: { scores[$0] < scores[$1] }),
            scores[worst] < policy.minimumConsistency
        else { return nil }
        return (worst, scores[worst])
    }
}
