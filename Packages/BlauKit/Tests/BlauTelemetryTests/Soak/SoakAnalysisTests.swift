import Foundation
import Testing

@testable import BlauTelemetry

/// The soak test's verdict (#76): the rules a long run is judged by.
@Suite struct SoakAnalysisTests {
    /// A healthy two-hour run sampled every minute: flat memory (with some
    /// jitter), steady chunk and reply latency, no drops.
    static func samples(
        count: Int = 121,
        memory: (Int) -> Double = { 40 + (($0 * 7) % 5 == 0 ? 0.8 : 0) },
        asrMilliseconds: (Int) -> Double = { _ in 12 },
        firstAudioMilliseconds: (Int) -> Double = { _ in 650 },
        dropped: Int64 = 0
    ) -> [SoakSample] {
        var asrSeconds = 0.0
        return (0..<count).map { minute in
            let chunks = Int64(minute) * 180
            if minute > 0 { asrSeconds += 180 * asrMilliseconds(minute) / 1_000 }
            return SoakSample(
                audioSeconds: Double(minute) * 60, wallSeconds: Double(minute) * 6,
                footprintBytes: UInt64(memory(minute) * 1_048_576), asrChunks: chunks, asrSeconds: asrSeconds,
                framesDelivered: Int64(minute) * 3_000, framesDropped: minute == count - 1 ? dropped : 0,
                userUtterances: minute * 4, agentReplies: minute * 4, topicBoundaries: minute / 2,
                rollovers: minute >= 72 ? 1 : 0, reseeds: minute >= 72 ? 1 : 0,
                firstAudioCount: minute > 0 ? 4 : 0,
                firstAudioMilliseconds: minute > 0 ? firstAudioMilliseconds(minute) : nil)
        }
    }

    static let outcome = SoakOutcome(
        lines: 480, backgroundBursts: 400, scriptedTopicChanges: 79, expectedRollovers: 1, userUtterances: 480,
        agentReplies: 480, userSegments: 480, userAccepted: 480, backgroundSegments: 410, backgroundRejected: 410,
        topicBoundaries: 70, rollovers: 1, reseeds: 1, connections: 2, failedTurns: 0)

    static func check(_ name: String, _ checks: [SoakCheck]) throws -> SoakCheck {
        try #require(checks.first { $0.name == name })
    }

    @Test func aHealthyRunPassesEveryCheck() {
        let checks = SoakAnalysis.checks(samples: Self.samples(), outcome: Self.outcome)
        #expect(
            checks.map(\.name) == [
                "memory.slope", "asr.chunkLatency", "realtime.firstAudio", "capture.droppedFrames",
                "conversation.complete", "realtime.rollover", "voiceid.background", "topics.count",
            ])
        for check in checks {
            #expect(check.passed, "\(check.name): \(check.measured) (\(check.limit)) \(check.detail ?? "")")
        }
    }

    @Test func memorySlopeIgnoresSpikesButCatchesALeak() throws {
        // Flat with large one-off spikes (an autorelease pool draining late).
        let spiky = Self.samples(memory: { $0 % 17 == 0 ? 60 : 40 })
        let slope = try #require(SoakAnalysis.memorySlope(spiky, warmUpFraction: 0.1))
        #expect(abs(slope) < 0.01, "\(slope)")

        // 3 MB per hour of audio: a leak.
        let leaking = Self.samples(memory: { 40 + Double($0) / 20 })
        let leak = try #require(SoakAnalysis.memorySlope(leaking, warmUpFraction: 0.1))
        #expect(abs(leak - 3) < 0.001)
        let check = try Self.check("memory.slope", SoakAnalysis.checks(samples: leaking, outcome: Self.outcome))
        #expect(!check.passed)
        #expect(check.measured == "+3.00 MB/h")

        // Growth during the warm-up only (caches filling) is fine.
        let warming = Self.samples(memory: { 30 + Double(min($0, 10)) })
        #expect(try Self.check("memory.slope", SoakAnalysis.checks(samples: warming, outcome: Self.outcome)).passed)
    }

    @Test func memoryWithoutReadingsFails() throws {
        var samples = Self.samples()
        for index in samples.indices { samples[index].footprintBytes = nil }
        let check = try Self.check("memory.slope", SoakAnalysis.checks(samples: samples, outcome: Self.outcome))
        #expect(!check.passed)
        #expect(check.measured == "n/a")
    }

    @Test func latencyThatCreepsUpFails() throws {
        // The recognizer's chunk time doubles over the run.
        let creeping = Self.samples(asrMilliseconds: { 10 + Double($0) / 6 })
        let asr = try Self.check("asr.chunkLatency", SoakAnalysis.checks(samples: creeping, outcome: Self.outcome))
        #expect(!asr.passed, "\(asr.measured)")

        // Replies arrive later and later.
        let slowing = Self.samples(firstAudioMilliseconds: { 600 + Double($0) * 8 })
        let reply = try Self.check("realtime.firstAudio", SoakAnalysis.checks(samples: slowing, outcome: Self.outcome))
        #expect(!reply.passed)
    }

    @Test func tinyLatenciesBelowTheNoiseFloorPass() throws {
        // A scripted recognizer: microseconds per chunk, tripling is noise.
        let tiny = Self.samples(asrMilliseconds: { $0 < 60 ? 0.02 : 0.06 })
        let check = try Self.check("asr.chunkLatency", SoakAnalysis.checks(samples: tiny, outcome: Self.outcome))
        #expect(check.passed, "\(check.measured)")
    }

    @Test func latenciesReadWellAtEveryScale() {
        #expect(SoakAnalysis.milliseconds(650) == "650.0 ms")
        #expect(SoakAnalysis.milliseconds(4.5671) == "4.567 ms")
        #expect(SoakAnalysis.milliseconds(0.042) == "42.00 µs")
        #expect(SoakAnalysis.milliseconds(0.00031) == "0.31 µs")
    }

    @Test func trendComparesTheEarlyAndLateThirds() throws {
        let trend = try #require(SoakAnalysis.trend([1, 1, 1, 5, 5, 5, 2, 2, 2]))
        #expect(trend.early == 1)
        #expect(trend.late == 2)
        #expect(trend.ratio == 2)
        #expect(SoakAnalysis.trend([1, 2]) == nil)
    }

    @Test func droppedFramesOverTheLimitFail() throws {
        let few = Self.samples(dropped: 100)
        #expect(
            try Self.check("capture.droppedFrames", SoakAnalysis.checks(samples: few, outcome: Self.outcome)).passed)
        let many = Self.samples(dropped: 1_000)
        let check = try Self.check("capture.droppedFrames", SoakAnalysis.checks(samples: many, outcome: Self.outcome))
        #expect(!check.passed)
        #expect(check.measured == "1000 of 361000")
    }

    @Test func aStalledConversationFails() throws {
        var outcome = Self.outcome
        outcome.agentReplies = 479
        #expect(
            !(try Self.check("conversation.complete", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
        outcome = Self.outcome
        outcome.failedTurns = 1
        #expect(
            !(try Self.check("conversation.complete", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
    }

    @Test func aMissingRenewalFails() throws {
        var outcome = Self.outcome
        outcome.rollovers = 0
        outcome.reseeds = 0
        outcome.connections = 1
        let check = try Self.check("realtime.rollover", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
        #expect(!check.passed)
        // A renewal that wasn't reseeded fails too.
        outcome = Self.outcome
        outcome.reseeds = 0
        #expect(
            !(try Self.check("realtime.rollover", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome)).passed)
        )
        // More renewals than required are fine.
        outcome = Self.outcome
        outcome.rollovers = 2
        outcome.reseeds = 2
        outcome.connections = 3
        #expect(
            try Self.check("realtime.rollover", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome)).passed)
    }

    @Test func backgroundSpeechMustBeRejected() throws {
        var outcome = Self.outcome
        outcome.backgroundRejected = 409
        #expect(
            !(try Self.check("voiceid.background", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
        outcome = Self.outcome
        outcome.userAccepted = 479
        #expect(
            !(try Self.check("voiceid.background", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
        // Background the VAD never heard isn't a pass.
        outcome = Self.outcome
        outcome.backgroundSegments = 0
        outcome.backgroundRejected = 0
        #expect(
            !(try Self.check("voiceid.background", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
    }

    @Test func topicCountMustBeSane() throws {
        func passes(_ boundaries: Int) throws -> Bool {
            var outcome = Self.outcome
            outcome.topicBoundaries = boundaries
            return try Self.check("topics.count", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome)).passed
        }
        #expect(try !passes(0))
        #expect(try !passes(38))
        #expect(try passes(39))
        #expect(try passes(79))
        #expect(try passes(120))
        #expect(try !passes(121), "flapping")
    }

    @Test func reportRoundTripsAndRendersMarkdown() throws {
        let device = BenchmarkDevice(
            modelIdentifier: "iPhone17,1", marketingName: "iPhone 16 Pro", chip: "A18 Pro",
            operatingSystem: "iOS 27.2", physicalMemoryBytes: 8 << 30, activeProcessorCount: 6, isSimulator: false)
        let report = SoakReport(
            device: device, startedAt: Date(timeIntervalSince1970: 1_800_000_000), wallSeconds: 726,
            setup: .init(
                audioSeconds: 7_200, speed: 10, recognizer: "scripted ASR", voiceActivity: "energy VAD",
                audio: "user speech, TV dialogue and silence", rolloverAfterSeconds: 432, sampleIntervalSeconds: 60),
            outcome: Self.outcome, samples: Self.samples())
        #expect(report.passed)
        #expect(report.failures.isEmpty)
        #expect(report.summary == "passed: 120.0 min of audio in 12.1 min, 8/8 checks")

        let decoded = try SoakReport.decode(report.jsonData())
        #expect(decoded == report)

        let markdown = report.markdown
        #expect(markdown.hasPrefix("## Long-session soak: passed"))
        #expect(markdown.contains("| `memory.slope` | pass |"))
        #expect(markdown.contains("iPhone 16 Pro (A18 Pro)"))
        #expect(markdown.contains("renewed after 7.2 min"))
        let rows = markdown.components(separatedBy: "\n").filter {
            $0.hasPrefix("| ") && $0.dropFirst(2).first?.isNumber == true
        }
        #expect(rows.count == 121)

        var failing = report
        failing.checks[0].passed = false
        #expect(!failing.passed)
        #expect(failing.summary.hasSuffix("(failed: memory.slope)"))
        #expect(failing.markdown.contains("**FAIL**"))
    }
}
