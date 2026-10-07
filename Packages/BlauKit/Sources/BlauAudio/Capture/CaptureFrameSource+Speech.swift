import BlauCore

extension CaptureFrameSource {
    /// The audio of a speech segment from the rolling history, or `nil` once
    /// it has scrolled out (the history keeps 30 s). The result is clipped
    /// to what is retained, so check its `sampleOffset` and `sampleCount`
    /// when the segment is old.
    public func audio(for segment: SpeechSegment) -> AudioFrame? {
        precondition(
            segment.sampleRate == AudioFrame.captureSampleRate,
            "Speech segments index the 16 kHz capture stream")
        return history(in: segment.sampleRange)
    }

    /// The audio from a speech onset up to `endOffset` (exclusive), for
    /// consumers that start work as soon as speech starts, such as voice ID
    /// scoring the first 1.5 s.
    public func audio(from onset: SpeechOnset, to endOffset: Int64) -> AudioFrame? {
        precondition(
            onset.sampleRate == AudioFrame.captureSampleRate,
            "Speech onsets index the 16 kHz capture stream")
        guard endOffset > onset.startOffset else { return nil }
        return history(in: onset.startOffset..<endOffset)
    }
}
