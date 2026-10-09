/// Everything the debug performance HUD (#71) shows at one moment.
///
/// The device half (frame rate, CPU, memory, thermal state), the signpost
/// latencies and the gauges come from BlauTelemetry itself
/// (`PerformanceHUDSampler`). The pipeline half comes from subsystems that
/// sit above BlauTelemetry, so the app's composition root fills
/// `PipelineReadings` from them.
public struct PerformanceHUDSnapshot: Sendable, Hashable {
    // MARK: Device

    /// Main-thread frame rate from the display link.
    public var frameRate: FrameRateReading?
    /// Process CPU since the previous sample; 100 is one core.
    public var cpuPercent: Double?
    public var memory: MemorySnapshot?
    public var thermalState: DeviceThermalState?

    // MARK: Pipeline

    public var pipeline: PipelineReadings

    // MARK: Signposts and gauges

    /// Every canonical interval timed since the HUD appeared.
    public var intervals: [SignpostLatencyTap.IntervalLatency]
    public var voiceScore: PerformanceGauges.Reading?
    public var voiceThreshold: PerformanceGauges.Reading?
    public var topicDepth: PerformanceGauges.Reading?
    public var topicThreshold: PerformanceGauges.Reading?

    /// The HUD's own CPU time as a share of one core (`0.01` is 1%).
    public var overhead: Double?

    public init(
        frameRate: FrameRateReading? = nil,
        cpuPercent: Double? = nil,
        memory: MemorySnapshot? = nil,
        thermalState: DeviceThermalState? = nil,
        pipeline: PipelineReadings = PipelineReadings(),
        intervals: [SignpostLatencyTap.IntervalLatency] = [],
        voiceScore: PerformanceGauges.Reading? = nil,
        voiceThreshold: PerformanceGauges.Reading? = nil,
        topicDepth: PerformanceGauges.Reading? = nil,
        topicThreshold: PerformanceGauges.Reading? = nil,
        overhead: Double? = nil
    ) {
        self.frameRate = frameRate
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.thermalState = thermalState
        self.pipeline = pipeline
        self.intervals = intervals
        self.voiceScore = voiceScore
        self.voiceThreshold = voiceThreshold
        self.topicDepth = topicDepth
        self.topicThreshold = topicThreshold
        self.overhead = overhead
    }

    /// The timed statistics for `interval`, if it ran since the HUD appeared.
    public func stats(for interval: PipelineInterval) -> LatencyStats? {
        intervals.first { $0.interval == interval }?.stats
    }
}

/// What the app reads from the voice pipeline for the HUD. Every field is
/// optional: a stage that isn't running (or isn't built yet) shows "–".
public struct PipelineReadings: Sendable, Hashable {
    /// Capture losses since the conversation audio started.
    public struct CaptureDrops: Sendable, Hashable {
        /// Hardware buffers the capture thread dropped (ring full).
        public var droppedBuffers: Int64
        /// Frames a slow subscriber (VAD, ASR) lost.
        public var subscriberDroppedFrames: Int64
        /// Buffers the converter failed on.
        public var conversionFailures: Int64

        public init(droppedBuffers: Int64, subscriberDroppedFrames: Int64, conversionFailures: Int64) {
            self.droppedBuffers = droppedBuffers
            self.subscriberDroppedFrames = subscriberDroppedFrames
            self.conversionFailures = conversionFailures
        }

        public var total: Int64 { droppedBuffers + subscriberDroppedFrames + conversionFailures }
    }

    /// The voice activity detector.
    public struct VoiceActivity: Sendable, Hashable {
        /// Whether a speech segment is open.
        public var isSpeech: Bool
        /// Model time per second of audio (`0.01` is 1%).
        public var modelLoad: Double
        /// Share of chunks that skipped the model for being quiet.
        public var skippedFraction: Double

        public init(isSpeech: Bool, modelLoad: Double, skippedFraction: Double) {
            self.isSpeech = isSpeech
            self.modelLoad = modelLoad
            self.skippedFraction = skippedFraction
        }
    }

    /// Streaming ASR counters, for when the `asr.chunk` signposts have no
    /// samples yet (they are only timed while the HUD shows).
    public struct Transcriber: Sendable, Hashable {
        public var chunks: Int64
        public var meanChunkMilliseconds: Double
        public var slowestChunkMilliseconds: Double

        public init(chunks: Int64, meanChunkMilliseconds: Double, slowestChunkMilliseconds: Double) {
            self.chunks = chunks
            self.meanChunkMilliseconds = meanChunkMilliseconds
            self.slowestChunkMilliseconds = slowestChunkMilliseconds
        }
    }

    /// Grok usage in the current conversation.
    public struct Usage: Sendable, Hashable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var responses: Int
        /// The estimated bill so far, in US dollars.
        public var estimatedCostUSD: Double?

        public init(inputTokens: Int, outputTokens: Int, responses: Int, estimatedCostUSD: Double?) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.responses = responses
            self.estimatedCostUSD = estimatedCostUSD
        }
    }

    /// The thermal and power policy's level and why (#75).
    public var performance: PerformanceSnapshot?
    public var capture: CaptureDrops?
    public var voiceActivity: VoiceActivity?
    public var transcriber: Transcriber?
    /// The turn orchestrator's state name (`listening`, `agentSpeaking`...).
    public var turnState: String?
    /// The realtime connection, described.
    public var connection: String?
    /// The realtime session's continuity (live, resuming, renewed...),
    /// described.
    public var session: String?
    /// End of utterance → first audio, from the turn orchestrator's window.
    public var firstAudio: LatencyStats?
    /// End of utterance → `response.done`.
    public var turnTime: LatencyStats?
    /// Each hop of the latency budget (#74), from the turn orchestrator's
    /// window: end of speech → EOU, the voice gate, commit → first audio,
    /// the first buffer and the total.
    public var latencyHops: [LatencyHop: LatencyStats]
    public var usage: Usage?
    /// Barge-ins this conversation and how fast the last one went silent,
    /// described.
    public var bargeIn: String?

    public init(
        performance: PerformanceSnapshot? = nil,
        capture: CaptureDrops? = nil,
        voiceActivity: VoiceActivity? = nil,
        transcriber: Transcriber? = nil,
        turnState: String? = nil,
        connection: String? = nil,
        session: String? = nil,
        firstAudio: LatencyStats? = nil,
        turnTime: LatencyStats? = nil,
        latencyHops: [LatencyHop: LatencyStats] = [:],
        usage: Usage? = nil,
        bargeIn: String? = nil
    ) {
        self.performance = performance
        self.capture = capture
        self.voiceActivity = voiceActivity
        self.transcriber = transcriber
        self.turnState = turnState
        self.connection = connection
        self.session = session
        self.firstAudio = firstAudio
        self.turnTime = turnTime
        self.latencyHops = latencyHops
        self.usage = usage
        self.bargeIn = bargeIn
    }
}
