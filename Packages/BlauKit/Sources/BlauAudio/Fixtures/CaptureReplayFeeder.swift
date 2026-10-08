import BlauCore
import Foundation

/// Plays a `ConversationAudioScript` into a `CaptureHub` the way the capture
/// engine would: 20 ms frames in stream order, in real time or faster.
///
/// Faster than real time, the consumers (VAD, ASR) may not keep up, and a
/// subscriber that falls more than the hub's `subscriberBuffer` behind
/// loses frames. The feeder therefore never runs more than `maximumLead`
/// ahead of `consumed`, the position the slowest consumer has reached, so
/// a replay is lossless at any speed.
///
/// **Turn-taking.** A person waits for Blau to finish answering before
/// speaking again. Faster than real time, Grok's (scripted) replies take
/// longer on the audio timeline than the gap the script leaves for them, so
/// before each line after the first the feeder calls `beforeLine` with the
/// line's index, which can wait until the previous lines are answered. The
/// pause doesn't count towards the pacing, so playback resumes at `speed`.
///
/// ```swift
/// let feeder = CaptureReplayFeeder(script: script, speed: 10)
/// try await feeder.feed(into: hub) { min(vad.statistics.samplesProcessed, await asr.receivedPosition ?? 0) }
/// hub.finish()
/// ```
public struct CaptureReplayFeeder: Sendable {
    public let script: ConversationAudioScript
    /// How many times faster than real time to play, or `nil` for as fast as
    /// the consumers go.
    public let speed: Double?
    /// Samples per frame (the capture engine's 20 ms by default).
    public let frameLength: Int
    /// How far ahead of the slowest consumer the feeder may get.
    public let maximumLead: Duration

    /// - Precondition: `speed` is positive when set, `frameLength > 0`.
    public init(
        script: ConversationAudioScript, speed: Double?, frameLength: Int = 320, maximumLead: Duration = .seconds(2)
    ) {
        precondition(speed.map { $0 > 0 } ?? true, "The speed must be positive")
        precondition(frameLength > 0, "Frames must hold at least one sample")
        self.script = script
        self.speed = speed
        self.frameLength = frameLength
        self.maximumLead = maximumLead
    }

    /// Feeds the whole script, then returns. The hub is left open.
    ///
    /// - Parameters:
    ///   - hub: Where the frames go.
    ///   - consumed: The stream position the slowest consumer has reached.
    ///     Subscribe every consumer to `hub` before calling this: one that
    ///     subscribes late never sees the first frames, and a sample count
    ///     it reports would lag the stream position forever.
    ///   - beforeLine: Called with a line's index (from 1) right before its
    ///     first sample is fed.
    ///   - progress: Called about once per second of audio with the
    ///     position fed so far.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func feed(
        into hub: CaptureHub,
        consumed: @Sendable () async -> Int64,
        beforeLine: (@Sendable (Int) async -> Void)? = nil,
        progress: (@Sendable (Int64) async -> Void)? = nil
    ) async throws {
        let clock = ContinuousClock()
        var start = clock.now
        var nextLine = 1
        let rate = Double(ConversationAudioScript.sampleRate)
        let lead = maximumLead.sampleCount(sampleRate: ConversationAudioScript.sampleRate)
        let reportEvery = Int64(ConversationAudioScript.sampleRate)
        var offset: Int64 = 0
        var nextReport = reportEvery
        while offset < script.totalSamples {
            try Task.checkCancellation()
            if let beforeLine, nextLine < script.lines.count,
                offset + Int64(frameLength) > script.lines[nextLine].sampleRange.lowerBound
            {
                let paused = clock.now
                await beforeLine(nextLine)
                start += clock.now - paused
                nextLine += 1
            }
            let frame = script.frame(at: offset, length: frameLength)
            hub.append(frame.samples, hostTime: nil)
            offset = frame.nextSampleOffset

            if let speed {
                // Sleep in steps of a few milliseconds rather than per frame:
                // at 10x a frame lasts 2 ms, close to a sleep's own overhead.
                let due = start + .seconds(Double(offset) / rate / speed)
                if due - clock.now > .milliseconds(4) { try await clock.sleep(until: due) }
            }
            while await offset - consumed() > lead {
                try await Task.sleep(for: .milliseconds(2))
            }
            if offset >= nextReport {
                await progress?(offset)
                nextReport += reportEvery
            }
        }
    }
}
