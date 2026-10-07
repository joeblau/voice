import BlauCore

/// The segmentation logic of `VoiceActivitySegmenter`, without audio, models
/// or concurrency: chunk-level speech probabilities plus 16 ms energy levels
/// in, speech boundaries out. Pure and synchronous, so it is tested with
/// synthetic probabilities.
///
/// **Decisions** follow Silero's streaming rules at chunk granularity
/// (256 ms): a chunk at or above `threshold` opens speech; once open, only
/// a chunk below `negativeThreshold` (or one below `threshold` with no
/// energy above the noise) counts as silence; speech ends when the silence
/// since the last voiced audio reaches the hangover.
///
/// **Boundaries** are refined inside the chunks to 16 ms subframes from the
/// signal's energy, because 256 ms chunks alone would put boundaries up to
/// a quarter second off:
/// - the onset is the first subframe above the noise floor plus
///   `energyMarginDecibels` in the triggering chunk, extended backwards
///   (up to `onsetLookback`) while the energy stays up, bridging gaps of
///   up to 80 ms;
/// - the end is the last such subframe of the last speech chunk, extended
///   forwards into the following chunks the same way.
/// When no subframe clears the energy threshold (very quiet speech), the
/// chunk edges are used. After voiced audio, a single speech chunk with no
/// energy is taken as the model's smoothing and doesn't move the end; a
/// second one in a row means the speech carries on too quietly to refine,
/// so both count.
///
/// **Minimum speech**: a candidate is confirmed (and `speechStarted` sent)
/// once its voiced span reaches `minimumSpeechDuration`; a candidate that
/// ends sooner is dropped. **Maximum segment**: a confirmed segment whose
/// voiced span would exceed `maximumSegmentDuration` is split at the
/// quietest subframe of the last `splitSearchWindow`.
struct SpeechSegmentationStateMachine {
    /// One analysed chunk.
    struct Chunk {
        /// First sample of the chunk in the stream.
        var startOffset: Int64
        var sampleCount: Int
        /// The model's speech probability (`0` when the model was skipped).
        var probability: Float
        /// RMS level in dBFS of each `subframeLength` subframe, in order;
        /// the last may cover fewer samples.
        var levels: [Float]

        var endOffset: Int64 { startOffset + Int64(sampleCount) }
    }

    /// Samples per energy subframe: 16 ms at 16 kHz.
    static let subframeLength = 256

    /// Bridged gaps when following the energy: 5 subframes, 80 ms.
    private static let maximumEnergyGap = 5

    /// Counters, for `VoiceActivityStatistics`.
    struct Counters: Hashable {
        var segments = 0
        var forcedSplits = 0
        var rejectedCandidates = 0
        var speechSamples: Int64 = 0
    }

    private struct Subframe {
        let offset: Int64
        let length: Int
        let level: Float
        var end: Int64 { offset + Int64(length) }
    }

    private struct Active {
        let id: Int
        /// Segment start, padding included.
        var start: Int64
        /// First voiced sample (refined onset, no padding).
        var voicedStart: Int64
        /// End of the last voiced audio (no padding).
        var voicedEnd: Int64
        var isConfirmed = false
        var isContinuation = false
        /// A silence chunk has been seen since the last speech chunk.
        var isInSilence = false
        /// Some subframe of the segment cleared the energy threshold, so
        /// energy (not chunk edges) places its end.
        var hasEnergy = false
        /// Consecutive speech chunks, since the last voiced audio, with no
        /// subframe above the energy threshold.
        var silentSpeechChunks = 0
        var probabilitySum: Float = 0
        var probabilityCount = 0
        var peakProbability: Float = 0
    }

    let configuration: VoiceActivityConfiguration
    let sampleRate: Int

    private let minimumSpeech: Int64
    private let minimumSilence: Int64
    private let maximumSegment: Int64
    private let splitWindow: Int64
    private let padding: Int64
    private let lookback: Int64
    private let subframeCapacity: Int

    private var subframes: [Subframe] = []
    private var active: Active?
    private var nextID = 0
    /// Nothing before this belongs to a new segment: the stream start or
    /// the end of the previous segment.
    private var floorOffset: Int64 = 0
    /// End of the audio processed so far.
    private(set) var processedEnd: Int64 = 0
    /// Tracked noise floor (dBFS), from chunks without speech.
    private(set) var noiseFloor: Float?
    private(set) var counters = Counters()

    /// Assumed noise floor before any silence has been measured.
    static let defaultNoiseFloor: Float = -65
    /// Energy refinement never treats audio quieter than this as speech.
    static let minimumSpeechLevel: Float = -72

    init(configuration: VoiceActivityConfiguration, sampleRate: Int = AudioFrame.captureSampleRate) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        func samples(_ duration: Duration) -> Int64 { duration.sampleCount(sampleRate: sampleRate) }
        minimumSpeech = samples(configuration.minimumSpeechDuration)
        minimumSilence = samples(configuration.minimumSilenceDuration)
        maximumSegment = samples(configuration.maximumSegmentDuration)
        splitWindow = samples(configuration.splitSearchWindow)
        padding = samples(configuration.speechPadding)
        lookback = samples(configuration.onsetLookback)
        // Enough history for the onset look-back and the split window, with
        // room for the chunks analysed since.
        let retained = max(lookback, splitWindow) + Int64(sampleRate) * 2
        subframeCapacity = Int(retained / Int64(Self.subframeLength)) + 1
    }

    /// Whether a confirmed segment is open.
    var isSpeechActive: Bool { active?.isConfirmed == true }

    /// Whether a segment or an unconfirmed candidate is open. While one is,
    /// every chunk must go through the model.
    var hasOpenSegment: Bool { active != nil }

    /// The level (dBFS) above which a subframe counts as voiced.
    var energyThreshold: Float {
        max((noiseFloor ?? Self.defaultNoiseFloor) + configuration.energyMarginDecibels, Self.minimumSpeechLevel)
    }

    /// Starts (or restarts, after a discontinuity) the stream at `offset`.
    /// Any open segment must have been closed with `finish(at:)`.
    mutating func begin(at offset: Int64) {
        precondition(active == nil, "Close the open segment before restarting the stream")
        subframes.removeAll(keepingCapacity: true)
        floorOffset = offset
        processedEnd = offset
    }

    // MARK: Processing

    /// Processes the next chunk, which must start where the previous one
    /// ended, and returns the boundaries it decided.
    mutating func process(_ chunk: Chunk) -> [VoiceActivityEvent] {
        precondition(chunk.startOffset == processedEnd, "Chunks must be contiguous")
        appendSubframes(of: chunk)
        processedEnd = chunk.endOffset

        var events: [VoiceActivityEvent] = []
        let probability = chunk.probability

        if active == nil {
            if probability >= configuration.threshold {
                open(at: chunk)
            } else {
                if probability < configuration.negativeThreshold {
                    updateNoiseFloor(with: chunk)
                }
                return events
            }
        } else {
            advance(with: chunk)
        }

        guard var segment = active else { return events }
        segment.probabilitySum += probability
        segment.probabilityCount += 1
        segment.peakProbability = max(segment.peakProbability, probability)
        if !segment.isConfirmed, segment.voicedEnd - segment.voicedStart >= minimumSpeech {
            segment.isConfirmed = true
            events.append(.speechStarted(onset(of: segment, detectedAt: chunk.endOffset)))
        }
        active = segment

        if segment.isConfirmed {
            events += splitIfTooLong(detectedAt: chunk.endOffset)
        }

        if let segment = active, segment.isInSilence, chunk.endOffset - segment.voicedEnd >= minimumSilence {
            events += close(reason: .silence, detectedAt: chunk.endOffset)
        }
        return events
    }

    /// Ends the stream at `offset` (the end of the audio received, which may
    /// be past `processedEnd` when a partial chunk wasn't analysed), closing
    /// an open segment with `.streamEnded`.
    mutating func finish(at offset: Int64) -> [VoiceActivityEvent] {
        processedEnd = max(processedEnd, offset)
        guard active != nil else { return [] }
        return close(reason: .streamEnded, detectedAt: processedEnd)
    }

    // MARK: Segments

    private mutating func open(at chunk: Chunk) {
        let threshold = energyThreshold
        let voicedStart = refinedOnset(in: chunk, threshold: threshold)
        var segment = Active(
            id: nextID,
            start: max(voicedStart - padding, floorOffset),
            voicedStart: voicedStart,
            voicedEnd: voicedStart
        )
        segment.hasEnergy = lastVoicedSubframe(in: chunk, threshold: threshold) != nil
        segment.voicedEnd = voicedEnd(
            after: segment.voicedStart, in: chunk, threshold: threshold, isSpeech: true, hasEnergy: segment.hasEnergy)
        nextID += 1
        active = segment
    }

    private mutating func advance(with chunk: Chunk) {
        guard var segment = active else { return }
        let threshold = energyThreshold
        let probability = chunk.probability
        let lastVoiced = lastVoicedSubframe(in: chunk, threshold: threshold)
        let hadEnergy = segment.hasEnergy
        segment.hasEnergy = hadEnergy || lastVoiced != nil

        if probability >= configuration.threshold {
            segment.isInSilence = false
            if lastVoiced == nil, hadEnergy {
                // The model says speech but nothing clears the energy
                // threshold. One such chunk after the words is the model's
                // smoothing; a second in a row is speech too quiet to
                // refine (a distant speaker in a noisy room), so it counts
                // whole, the first one included.
                segment.silentSpeechChunks += 1
                if segment.silentSpeechChunks >= 2 {
                    segment.voicedEnd = max(segment.voicedEnd, chunk.endOffset)
                }
            } else {
                segment.silentSpeechChunks = 0
                segment.voicedEnd = voicedEnd(
                    after: segment.voicedEnd, in: chunk, threshold: threshold, isSpeech: true, hasEnergy: hadEnergy)
            }
        } else if probability >= configuration.negativeThreshold, lastVoiced != nil, !segment.isInSilence {
            // Between the thresholds with energy: Silero keeps the state;
            // the speech continues.
            segment.silentSpeechChunks = 0
            segment.voicedEnd = voicedEnd(
                after: segment.voicedEnd, in: chunk, threshold: threshold, isSpeech: true, hasEnergy: hadEnergy)
        } else {
            // Silence (or an undecided chunk with no energy): only audio
            // contiguous with the speech extends it.
            segment.silentSpeechChunks = 0
            segment.isInSilence = true
            segment.voicedEnd = voicedEnd(
                after: segment.voicedEnd, in: chunk, threshold: threshold, isSpeech: false, hasEnergy: hadEnergy)
        }
        active = segment
    }

    /// Splits the open segment while its voiced span is over the maximum.
    private mutating func splitIfTooLong(detectedAt: Int64) -> [VoiceActivityEvent] {
        var events: [VoiceActivityEvent] = []
        while var segment = active, segment.voicedEnd + padding - segment.start > maximumSegment {
            let limit = segment.start + maximumSegment
            let split = quietestPoint(in: max(segment.start + 1, limit - splitWindow)..<limit) ?? limit
            let ended = SpeechSegment(
                id: segment.id,
                sampleRange: segment.start..<split,
                sampleRate: sampleRate,
                isContinuation: segment.isContinuation,
                endReason: .maximumDuration,
                detectedAt: detectedAt,
                peakProbability: segment.peakProbability,
                meanProbability: segment.probabilityCount > 0
                    ? segment.probabilitySum / Float(segment.probabilityCount) : 0
            )
            events.append(.speechEnded(ended))
            counters.segments += 1
            counters.forcedSplits += 1
            counters.speechSamples += ended.sampleCount

            segment = Active(
                id: nextID,
                start: split,
                voicedStart: split,
                voicedEnd: segment.voicedEnd,
                isConfirmed: true,
                isContinuation: true,
                isInSilence: segment.isInSilence,
                hasEnergy: segment.hasEnergy,
                silentSpeechChunks: segment.silentSpeechChunks,
                probabilitySum: 0,
                probabilityCount: 0,
                peakProbability: 0
            )
            nextID += 1
            active = segment
            events.append(.speechStarted(onset(of: segment, detectedAt: detectedAt)))
        }
        return events
    }

    private mutating func close(reason: SpeechSegment.EndReason, detectedAt: Int64) -> [VoiceActivityEvent] {
        guard let segment = active else { return [] }
        active = nil
        guard segment.isConfirmed else {
            counters.rejectedCandidates += 1
            return []
        }
        let end = max(min(segment.voicedEnd + padding, processedEnd, segment.start + maximumSegment), segment.start)
        floorOffset = end
        let ended = SpeechSegment(
            id: segment.id,
            sampleRange: segment.start..<end,
            sampleRate: sampleRate,
            isContinuation: segment.isContinuation,
            endReason: reason,
            detectedAt: detectedAt,
            peakProbability: segment.peakProbability,
            meanProbability: segment.probabilityCount > 0
                ? segment.probabilitySum / Float(segment.probabilityCount) : 0
        )
        counters.segments += 1
        counters.speechSamples += ended.sampleCount
        return [.speechEnded(ended)]
    }

    private func onset(of segment: Active, detectedAt: Int64) -> SpeechOnset {
        SpeechOnset(
            segmentID: segment.id,
            startOffset: segment.start,
            sampleRate: sampleRate,
            isContinuation: segment.isContinuation,
            detectedAt: detectedAt
        )
    }

    // MARK: Energy

    private mutating func appendSubframes(of chunk: Chunk) {
        var offset = chunk.startOffset
        for level in chunk.levels {
            let length = Int(min(Int64(Self.subframeLength), chunk.endOffset - offset))
            guard length > 0 else { break }
            subframes.append(Subframe(offset: offset, length: length, level: level))
            offset += Int64(length)
        }
        if subframes.count > subframeCapacity * 2 {
            subframes.removeFirst(subframes.count - subframeCapacity)
        }
    }

    /// The subframes from `offset` on (searching from the newest, since
    /// callers only look at the last chunk or two).
    private func subframeIndices(from offset: Int64) -> Range<Int> {
        let first = subframes.lastIndex { $0.offset < offset }.map { $0 + 1 } ?? subframes.startIndex
        return first..<subframes.endIndex
    }

    private func subframeIndices(in chunk: Chunk) -> Range<Int> {
        subframeIndices(from: chunk.startOffset)
    }

    private func lastVoicedSubframe(in chunk: Chunk, threshold: Float) -> Int? {
        subframeIndices(in: chunk).last { subframes[$0].level >= threshold }
    }

    /// The first voiced sample of the speech that triggered in `chunk`.
    private func refinedOnset(in chunk: Chunk, threshold: Float) -> Int64 {
        let indices = subframeIndices(in: chunk)
        guard let first = indices.first(where: { subframes[$0].level >= threshold }) else {
            return max(chunk.startOffset, floorOffset)
        }
        let earliest = max(floorOffset, chunk.startOffset - lookback)
        var onset = subframes[first].offset
        var gap = 0
        var index = first - 1
        while index >= subframes.startIndex, subframes[index].offset >= earliest {
            if subframes[index].level >= threshold {
                onset = subframes[index].offset
                gap = 0
            } else {
                gap += 1
                if gap > Self.maximumEnergyGap { break }
            }
            index -= 1
        }
        return max(onset, floorOffset)
    }

    /// The end of the voiced audio after `current`, given `chunk`.
    ///
    /// For a speech chunk, any voiced subframe in it counts (the model says
    /// it is speech). A speech chunk with none counts whole while the
    /// segment has shown no energy at all (speech too quiet to refine);
    /// after energy, `advance(with:)` decides (one such chunk is the
    /// model's smoothing, two in a row are quiet speech). For other chunks
    /// only subframes contiguous with `current` (bridging short gaps)
    /// extend it.
    private func voicedEnd(
        after current: Int64, in chunk: Chunk, threshold: Float, isSpeech: Bool, hasEnergy: Bool
    ) -> Int64 {
        if isSpeech {
            if let last = lastVoicedSubframe(in: chunk, threshold: threshold) {
                return max(current, subframes[last].end)
            }
            return chunk.probability >= configuration.threshold && !hasEnergy ? max(current, chunk.endOffset) : current
        }
        // Count the quiet subframes between `current` and the chunk too.
        var end = current
        var gap = 0
        for index in subframeIndices(from: current) {
            if subframes[index].level >= threshold {
                end = subframes[index].end
                gap = 0
            } else {
                gap += 1
                if gap > Self.maximumEnergyGap { break }
            }
        }
        return end
    }

    /// The middle of the quietest subframe that lies entirely in `range`.
    private func quietestPoint(in range: Range<Int64>) -> Int64? {
        var best: Subframe?
        for subframe in subframes where subframe.offset >= range.lowerBound && subframe.end <= range.upperBound {
            if best == nil || subframe.level < best!.level {
                best = subframe
            }
        }
        return best.map { $0.offset + Int64($0.length / 2) }
    }

    /// Tracks the room's level from a chunk the model calls silence: the
    /// 20th percentile of its subframes, ignoring digital silence (a
    /// filled capture gap, or voice processing muting the input), which
    /// says nothing about the room.
    private mutating func updateNoiseFloor(with chunk: Chunk) {
        let levels = chunk.levels.filter { $0 > Self.digitalSilenceLevel }.sorted()
        guard !levels.isEmpty else { return }
        let level = max(levels[levels.count / 5], Self.lowestNoiseFloor)
        guard let floor = noiseFloor else {
            noiseFloor = level
            return
        }
        // Fall quickly when the room gets quieter; rise more slowly, so one
        // noisy chunk doesn't raise the bar for the next words (the model
        // already called these chunks silence, so a real change still
        // settles within about a second).
        let rate: Float = level < floor ? 0.5 : 0.25
        noiseFloor = floor + rate * (level - floor)
    }

    /// Subframes quieter than this are digital silence.
    static let digitalSilenceLevel: Float = -100
    /// The tracked floor never goes below this.
    static let lowestNoiseFloor: Float = -90
}
