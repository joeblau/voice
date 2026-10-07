/// Confirms or vetoes a candidate boundary and titles a topic.
///
/// `TopicLabelingService` tries its labelers in order (Foundation Models,
/// then xAI, then keywords) and normalizes whatever comes back with
/// `TopicTitleFormatter`.
public protocol TopicLabeler: Sendable {
    var source: TopicLabelSource { get }

    /// Whether the labeler can run now (Apple Intelligence enabled and the
    /// model ready, an xAI key stored, …). Cheap.
    func isAvailable() async -> Bool

    /// Labels `request`.
    ///
    /// - Throws: `TopicLabelerError`, or the underlying service's error. The
    ///   service then moves on to the next labeler.
    func label(_ request: TopicLabelRequest) async throws -> TopicShift
}

/// Why a labeler gave up.
public enum TopicLabelerError: Error, Hashable, Sendable {
    /// The labeler can't run on this device right now.
    case unavailable(String)
    /// The request didn't fit in the model's context window, even trimmed.
    case contextWindowExceeded
    /// The model's reply couldn't be turned into a label.
    case invalidResponse(String)
    /// The labeler took longer than the service's timeout.
    case timedOut
    /// The request had no text to label.
    case emptyRequest
}
