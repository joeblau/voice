#if canImport(FoundationModels)
    import FoundationModels

    /// Runs `TopicLabelBenchmark` on the labeler Blau ships,
    /// `FoundationModelsTopicLabeler`, so the numbers include everything a
    /// real label costs: the instructions and prompt from `TopicLabelPrompt`,
    /// the token budget and `TopicLabelPrompt.fit`, greedy sampling, and the
    /// retries (a smaller prompt, or plain text after a refusal).
    ///
    /// Sessions come from the labeler's own seam
    /// (`prepareSession(for:prewarm:)`), so a prewarmed session has exactly
    /// the model and instructions production would use.
    public struct FoundationModelsLabelBenchmarkGenerator: TopicLabelGenerator {
        let labeler: FoundationModelsTopicLabeler

        public init(labeler: FoundationModelsTopicLabeler = FoundationModelsTopicLabeler()) {
            self.labeler = labeler
        }

        public func unavailableReason() async -> String? {
            switch labeler.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "device not eligible"
                case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
                case .modelNotReady: return "the model is not ready (still downloading)"
                @unknown default: return "unavailable (\(reason))"
                }
            @unknown default:
                return "unknown availability"
            }
        }

        public func makeSession(for request: TopicLabelRequest, prewarm: Bool) async -> any TopicLabelSession {
            Session(
                labeler: labeler, request: request,
                prepared: labeler.prepareSession(for: request, prewarm: prewarm))
        }

        struct Session: TopicLabelSession {
            let labeler: FoundationModelsTopicLabeler
            let request: TopicLabelRequest
            let prepared: FoundationModelsTopicLabeler.PreparedSession

            func label() async throws -> TopicShift {
                try await labeler.label(request, preparedSession: prepared)
            }
        }
    }
#endif
