import BlauCore

/// A transcriber `TranscriberRouter` can hand the conversation to and take
/// it back from at an utterance boundary.
///
/// Both of Blau's transcribers read the shared capture stream and its 30 s
/// history, so the one taking over starts at the end of the last utterance
/// the other committed (`start(resumingAt:)`) and reads the audio since
/// then from the history: speech that began while the engines were
/// switching is neither lost nor transcribed twice.
public protocol RoutableTranscriber: Transcriber {
    /// Starts transcribing the audio from `position` on (on the capture
    /// stream's timeline), read back from the capture history where it is
    /// still retained. Audio before `position` is never transcribed. `nil`
    /// is the same as `start()`: from the next live frame.
    func start(resumingAt position: Duration?) async throws

    /// Utterances committed from now on belong to `id`.
    func setConversationID(_ id: ConversationID) async

    /// Stops and ends `events` for good.
    func finish() async
}

extension ParakeetStreamingTranscriber: RoutableTranscriber {}
