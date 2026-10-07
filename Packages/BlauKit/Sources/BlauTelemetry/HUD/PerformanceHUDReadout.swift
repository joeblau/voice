/// The text of the performance HUD for one snapshot: a few rows when
/// compact, every subsystem in sections when expanded. The app renders the
/// rows as they are, so formatting is tested here.
public struct PerformanceHUDReadout: Sendable, Hashable {
    /// How much a value deserves attention.
    public enum Level: Int, Sendable, Hashable, Comparable {
        case normal
        case warning
        case critical

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public var label: String
        public var value: String
        public var level: Level

        public init(label: String, value: String, level: Level = .normal) {
            self.label = label
            self.value = value
            self.level = level
        }

        public var id: String { label }
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public var title: String
        public var rows: [Row]

        public init(title: String, rows: [Row]) {
            self.title = title
            self.rows = rows
        }

        public var id: String { title }
    }

    /// What the compact HUD shows.
    public var compact: [Row]
    /// What the expanded HUD shows.
    public var sections: [Section]

    /// The placeholder for a value that isn't available.
    public static let placeholder = "–"

    public init(_ snapshot: PerformanceHUDSnapshot) {
        let fps = Self.frameRateRow(snapshot.frameRate)
        let cpu = Self.cpuRow(snapshot.cpuPercent)
        let memory = Self.memoryRow(snapshot.memory)
        let thermal = Self.thermalRow(snapshot.thermalState)
        let pipeline = snapshot.pipeline

        compact = [
            fps, cpu, memory, thermal,
            Row(label: "EOU → audio", value: pipeline.firstAudio.map(Self.percentiles) ?? Self.placeholder),
        ]

        let device = [
            fps, cpu, memory, thermal,
            Self.performanceLevelRow(pipeline.performance),
            Self.overheadRow(snapshot.overhead),
        ]

        let audio = [
            Self.captureRow(pipeline.capture),
            Self.voiceActivityRow(pipeline.voiceActivity),
        ]

        let speech = [
            Row(
                label: "ASR chunk",
                value: snapshot.stats(for: .asrChunk).map(Self.latency)
                    ?? pipeline.transcriber.map(Self.transcriber) ?? Self.placeholder),
            Row(
                label: "EOU decision",
                value: snapshot.stats(for: .asrEndOfUtterance).map(Self.latency) ?? Self.placeholder),
            Row(label: "Voice score", value: Self.score(snapshot.voiceScore, threshold: snapshot.voiceThreshold)),
        ]

        var realtime = [
            Row(label: "Turn", value: pipeline.turnState ?? Self.placeholder),
            Row(label: "Realtime", value: pipeline.connection ?? Self.placeholder),
            Row(label: "Session", value: pipeline.session ?? Self.placeholder),
            Row(label: "EOU → audio", value: pipeline.firstAudio.map(Self.latency) ?? Self.placeholder),
            Row(label: "Turn time", value: pipeline.turnTime.map(Self.latency) ?? Self.placeholder),
        ]
        if let usage = pipeline.usage {
            realtime.append(
                Row(
                    label: "Tokens",
                    value: "\(usage.inputTokens) in · \(usage.outputTokens) out · \(usage.responses) resp"))
            realtime.append(Row(label: "Cost", value: usage.estimatedCostUSD.map(Self.cost) ?? Self.placeholder))
        } else {
            realtime.append(Row(label: "Tokens", value: Self.placeholder))
            realtime.append(Row(label: "Cost", value: Self.placeholder))
        }
        realtime.append(Row(label: "Barge-in", value: pipeline.bargeIn ?? Self.placeholder))

        let topics = [
            Row(label: "Topic depth", value: Self.score(snapshot.topicDepth, threshold: snapshot.topicThreshold))
        ]

        let signposts = snapshot.intervals.map { entry in
            Row(label: entry.interval.name.description, value: Self.latency(entry.stats))
        }

        sections = [
            Section(title: "Device", rows: device),
            Section(title: "Audio", rows: audio),
            Section(title: "Speech", rows: speech),
            Section(title: "Grok", rows: realtime),
            Section(title: "Topics", rows: topics),
            Section(
                title: "Signposts",
                rows: signposts.isEmpty ? [Row(label: "Intervals", value: Self.placeholder)] : signposts),
        ]
    }

    /// The highest level of any row, for tinting the compact HUD.
    public var level: Level {
        sections.flatMap(\.rows).map(\.level).max() ?? .normal
    }

    /// The row `label` in any section (the first match), for tests.
    public func row(_ label: String) -> Row? {
        sections.lazy.flatMap(\.rows).first { $0.label == label }
    }

    // MARK: Rows

    static func frameRateRow(_ reading: FrameRateReading?) -> Row {
        guard let reading else { return Row(label: "FPS", value: placeholder) }
        var value = "\(Int(reading.framesPerSecond.rounded()))"
        var level = Level.normal
        if let target = reading.targetFramesPerSecond {
            value += " / \(Int(target.rounded()))"
            if reading.framesPerSecond < target * 0.5 {
                level = .critical
            } else if reading.framesPerSecond < target * 0.9 {
                level = .warning
            }
        }
        if reading.droppedFrames > 0 {
            value += " · \(reading.droppedFrames) dropped"
            level = max(level, .warning)
        }
        return Row(label: "FPS", value: value, level: level)
    }

    static func cpuRow(_ percent: Double?) -> Row {
        guard let percent else { return Row(label: "CPU", value: placeholder) }
        let level: Level = percent >= 150 ? .critical : percent >= 80 ? .warning : .normal
        return Row(label: "CPU", value: "\(Int(percent.rounded()))%", level: level)
    }

    static func memoryRow(_ memory: MemorySnapshot?) -> Row {
        guard let memory else { return Row(label: "Memory", value: placeholder) }
        var value = bytes(memory.physicalFootprint)
        var level = Level.normal
        if let available = memory.available {
            value += " · \(bytes(available)) free"
            if available < 150 * 1_048_576 {
                level = .critical
            } else if available < 300 * 1_048_576 {
                level = .warning
            }
        }
        return Row(label: "Memory", value: value, level: level)
    }

    static func thermalRow(_ state: DeviceThermalState?) -> Row {
        guard let state else { return Row(label: "Thermal", value: placeholder) }
        let level: Level =
            switch state {
            case .nominal, .fair: .normal
            case .serious: .warning
            case .critical: .critical
            }
        return Row(label: "Thermal", value: state.rawValue, level: level)
    }

    /// `reduced · thermal state serious`: the thermal and power policy's
    /// level (#75) and its strictest reason.
    static func performanceLevelRow(_ snapshot: PerformanceSnapshot?) -> Row {
        guard let snapshot else { return Row(label: "Perf level", value: placeholder) }
        var value = snapshot.level.rawValue
        if let reason = snapshot.reasons.first {
            value += " · \(reason)"
        }
        if snapshot.isRecovering {
            value += " · recovering"
        }
        let level: Level =
            switch snapshot.level {
            case .normal: .normal
            case .reduced: .warning
            case .minimal: .critical
            }
        return Row(label: "Perf level", value: value, level: level)
    }

    static func overheadRow(_ overhead: Double?) -> Row {
        guard let overhead else { return Row(label: "HUD cost", value: placeholder) }
        return Row(
            label: "HUD cost", value: "\(percent(overhead)) CPU", level: overhead >= 0.01 ? .warning : .normal)
    }

    static func captureRow(_ drops: PipelineReadings.CaptureDrops?) -> Row {
        guard let drops else { return Row(label: "Capture", value: placeholder) }
        guard drops.total > 0 else { return Row(label: "Capture", value: "no drops") }
        var parts: [String] = []
        if drops.droppedBuffers > 0 { parts.append("\(drops.droppedBuffers) buf") }
        if drops.subscriberDroppedFrames > 0 { parts.append("\(drops.subscriberDroppedFrames) sub") }
        if drops.conversionFailures > 0 { parts.append("\(drops.conversionFailures) conv") }
        return Row(label: "Capture", value: "dropped " + parts.joined(separator: " · "), level: .warning)
    }

    static func voiceActivityRow(_ vad: PipelineReadings.VoiceActivity?) -> Row {
        guard let vad else { return Row(label: "VAD", value: placeholder) }
        return Row(
            label: "VAD",
            value:
                "\(vad.isSpeech ? "speech" : "silence") · model \(percent(vad.modelLoad)) · skip \(percent(vad.skippedFraction))"
        )
    }

    // MARK: Formatting

    /// `last 42 · p50 40 · p95 58 ms (n=120)`.
    static func latency(_ stats: LatencyStats) -> String {
        "last \(milliseconds(stats.last)) · p50 \(milliseconds(stats.p50)) · p95 \(milliseconds(stats.p95)) ms (n=\(stats.totalCount))"
    }

    /// `p50 610 · p95 900 ms`, for the compact HUD.
    static func percentiles(_ stats: LatencyStats) -> String {
        "p50 \(milliseconds(stats.p50)) · p95 \(milliseconds(stats.p95)) ms"
    }

    static func transcriber(_ asr: PipelineReadings.Transcriber) -> String {
        guard asr.chunks > 0 else { return placeholder }
        return
            "mean \(milliseconds(asr.meanChunkMilliseconds)) · max \(milliseconds(asr.slowestChunkMilliseconds)) ms (n=\(asr.chunks))"
    }

    static func score(_ reading: PerformanceGauges.Reading?, threshold: PerformanceGauges.Reading?) -> String {
        guard let reading else { return placeholder }
        var value = decimal(reading.value, places: 2)
        if let threshold { value += " (thr \(decimal(threshold.value, places: 2)))" }
        return value
    }

    /// `$0.42 est.`; three decimals below ten cents.
    static func cost(_ dollars: Double) -> String {
        "$\(decimal(dollars, places: dollars < 0.1 ? 3 : 2)) est."
    }

    /// Whole milliseconds from 10 ms up, one decimal below.
    static func milliseconds(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))" : decimal(value, places: 1)
    }

    /// `0.04%` style: two decimals below 1%, one below 10%, none above.
    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        let places = value < 1 ? 2 : value < 10 ? 1 : 0
        return "\(decimal(value, places: places))%"
    }

    /// `212 MB` below a gigabyte, `1.6 GB` above.
    static func bytes(_ count: UInt64) -> String {
        let megabytes = count.megabytes
        return megabytes >= 1_024 ? "\(decimal(megabytes / 1_024, places: 1)) GB" : "\(Int(megabytes.rounded())) MB"
    }

    /// `value` with exactly `places` decimals, without Foundation's
    /// locale-dependent formatting (the HUD always uses a dot).
    static func decimal(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return placeholder }
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        let scaled = (abs(value) * scale).rounded()
        let sign = value < 0 && scaled > 0 ? "-" : ""
        let whole = Int(scaled / scale)
        guard places > 0 else { return "\(sign)\(whole)" }
        let fraction = Int(scaled - Double(whole) * scale)
        let digits = String(fraction)
        return "\(sign)\(whole).\(String(repeating: "0", count: places - digits.count))\(digits)"
    }
}
