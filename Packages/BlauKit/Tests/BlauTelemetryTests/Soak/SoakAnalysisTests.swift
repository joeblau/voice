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
        dropped: Int64 = 0,
        subscriberDropped: Int64 = 0
    ) -> [SoakSample] {
        var asrSeconds = 0.0
        return (0..<count).map { minute in
            let chunks = Int64(minute) * 180
            if minute > 0 { asrSeconds += 180 * asrMilliseconds(minute) / 1_000 }
            let isLast = minute == count - 1
            // As `CaptureStatistics.droppedFrames(frameLength:)` counts them:
            // capture drops plus subscriber drops.
            return SoakSample(
                audioSeconds: Double(minute) * 60, wallSeconds: Double(minute) * 6,
                footprintBytes: UInt64(memory(minute) * 1_048_576), asrChunks: chunks, asrSeconds: asrSeconds,
                framesDelivered: Int64(minute) * 3_000, framesDropped: isLast ? dropped + subscriberDropped : 0,
                subscriberFramesDropped: isLast ? subscriberDropped : 0,
                userUtterances: minute * 4, agentReplies: minute * 4, topicBoundaries: minute / 2,
                rollovers: minute >= 72 ? 1 : 0, reseeds: minute >= 72 ? 1 : 0,
                firstAudioCount: minute > 0 ? 4 : 0,
                firstAudioMilliseconds: minute > 0 ? firstAudioMilliseconds(minute) : nil)
        }
    }

    static let outcome = SoakOutcome(
        lines: 480, backgroundBursts: 400, scriptedTopicChanges: 79, expectedRollovers: 1, userUtterances: 480,
        agentReplies: 480, userScores: 960, userAccepted: 960, backgroundScores: 410, backgroundRejected: 410,
        gateCommitted: 480, gateDiscarded: 0,
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

    /// The live heap is reported beside the footprint, so a report tells
    /// the allocator keeping freed memory (heap flat) from the app holding
    /// more (heap climbing too), #183. Only the footprint is judged.
    @Test func theLiveHeapIsReportedBesideTheFootprint() throws {
        var climbing = Self.samples(memory: { 40 + Double($0) / 20 })
        for index in climbing.indices {
            climbing[index].heapInUseBytes = 20 << 20
        }
        let flatHeap = try #require(SoakAnalysis.heapSlope(climbing, warmUpFraction: 0.1))
        #expect(abs(flatHeap) < 0.001)
        let check = try Self.check("memory.slope", SoakAnalysis.checks(samples: climbing, outcome: Self.outcome))
        #expect(!check.passed, "the footprint is what's judged")
        #expect(check.detail?.contains("live heap +0.00 MB/h, 20.0 MB → 20.0 MB") == true, "\(check.detail ?? "")")

        var holding = climbing
        for index in holding.indices { holding[index].heapInUseBytes = UInt64((20 + Double(index) / 20) * 1_048_576) }
        let growing = try #require(SoakAnalysis.heapSlope(holding, warmUpFraction: 0.1))
        #expect(abs(growing - 3) < 0.001)

        // Older reports have no heap readings: the detail is the footprint's.
        let old = try Self.check("memory.slope", SoakAnalysis.checks(samples: Self.samples(), outcome: Self.outcome))
        #expect(old.detail?.contains("live heap") == false)
        #expect(SoakAnalysis.heapSlope(Self.samples(), warmUpFraction: 0.1) == nil)
    }

    @Test func theHeapIsReadFromEveryZone() {
        // Other tests allocate and free alongside this one, so only what
        // can't move backwards is checked.
        let buffer = [UInt8](repeating: 1, count: 8 << 20)
        let heap = HeapUsage.current()
        #expect(heap.inUse >= UInt64(buffer.count), "a live 8 MB allocation counts")
        #expect(heap.reserved >= heap.inUse)
        #expect(buffer.count == 8 << 20)
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
        #expect(check.measured == "1000 of 361000 lost in capture, 0 of 360000 missed by a subscriber")
    }

    /// Frames a subscriber missed were published: they count once (the
    /// sample's `framesDropped` already holds them) and as a share of the
    /// frames published, not of the published plus the dropped.
    @Test func subscriberDropsCountOnceAgainstThePublishedFrames() throws {
        func check(capture: Int64, subscriber: Int64) throws -> SoakCheck {
            try Self.check(
                "capture.droppedFrames",
                SoakAnalysis.checks(
                    samples: Self.samples(dropped: capture, subscriberDropped: subscriber), outcome: Self.outcome))
        }

        // 300 of 360,000 published frames missed (0.083%) and nothing lost
        // in capture. Counting the drops twice (600 of 360,600, 0.17%)
        // would fail it.
        let missed = try check(capture: 0, subscriber: 300)
        #expect(missed.passed, "\(missed.measured)")
        #expect(missed.measured == "0 of 360000 lost in capture, 300 of 360000 missed by a subscriber")
        let loss = SoakAnalysis.frameLoss(try #require(Self.samples(subscriberDropped: 300).last))
        #expect(loss == .init(lostInCapture: 0, captured: 360_000, missedBySubscribers: 300, published: 360_000))

        // Both kinds at once, each under the limit: 300 of 360,300 lost in
        // capture and 300 of 360,000 missed. Adding the subscriber drops a
        // second time (900 of 360,900, 0.25%) would fail it.
        let both = try check(capture: 300, subscriber: 300)
        #expect(both.passed, "\(both.measured)")
        #expect(both.measured == "300 of 360300 lost in capture, 300 of 360000 missed by a subscriber")

        // Over the limit on either side fails.
        #expect(try !check(capture: 0, subscriber: 400).passed)
        #expect(try !check(capture: 400, subscriber: 0).passed)
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
        // A user line the gate kept from Grok fails.
        outcome = Self.outcome
        outcome.gateCommitted = 479
        outcome.gateDiscarded = 1
        #expect(
            !(try Self.check("voiceid.background", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed))
        // The TV's own utterances kept back (with a real recognizer) are fine.
        outcome = Self.outcome
        outcome.gateDiscarded = 12
        #expect(
            try Self.check("voiceid.background", SoakAnalysis.checks(samples: Self.samples(), outcome: outcome))
                .passed)
        // Background the VAD never heard isn't a pass.
        outcome = Self.outcome
        outcome.backgroundScores = 0
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

    /// A Parakeet run (`SOAK_ASR=parakeet`) on synthesized speech: the model
    /// may split or miss a line and transcribes the TV, and the topics
    /// follow what it heard, so the line-exact checks loosen.
    static let recognizedOutcome = SoakOutcome(
        lines: 480, backgroundBursts: 400, scriptedTopicChanges: 79, expectedRollovers: 1, userUtterances: 451,
        agentReplies: 451, userScores: 960, userAccepted: 960, backgroundScores: 410, backgroundRejected: 410,
        gateCommitted: 451, gateDiscarded: 37,
        topicBoundaries: 14, rollovers: 1, reseeds: 1, connections: 2, failedTurns: 0, transcript: .recognized)

    @Test func aRecognizedTranscriptIsJudgedAllowingForTheModel() throws {
        func verdicts(_ change: (inout SoakOutcome) -> Void = { _ in }) -> [String: Bool] {
            var outcome = Self.recognizedOutcome
            change(&outcome)
            let checks = SoakAnalysis.checks(samples: Self.samples(), outcome: outcome)
            return Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.passed) })
        }

        // 451 of 480 lines (94%, at least 90% needed), every one answered,
        // the TV's utterances kept back, few topics: a pass.
        #expect(verdicts().values.allSatisfy { $0 }, "\(verdicts())")
        // The same counts fail line by line with the scripted transcript.
        let scripted = verdicts { $0.transcript = .scripted }
        #expect(scripted["conversation.complete"] == false)
        #expect(scripted["voiceid.background"] == false)
        #expect(scripted["topics.count"] == false)

        // conversation.complete: at least 432 utterances and replies (90% of
        // 480), more than the lines (split lines) is fine, nothing left
        // waiting at the end, no failed turn.
        #expect(
            verdicts {
                $0.userUtterances = 432
                $0.agentReplies = 432
            }["conversation.complete"] == true)
        #expect(
            verdicts {
                $0.userUtterances = 431
                $0.agentReplies = 431
            }["conversation.complete"] == false)
        #expect(
            verdicts {
                $0.userUtterances = 530
                $0.agentReplies = 530
            }["conversation.complete"] == true)
        // A line split wider than the merge window whose first turn the
        // second half interrupted before Grok's audio: that utterance has
        // no reply of its own, the next reply answers both. A pass.
        #expect(verdicts { $0.agentReplies = 450 }["conversation.complete"] == true, "an interrupted split")
        #expect(verdicts { $0.agentReplies = 432 }["conversation.complete"] == true, "19 interrupted splits")
        #expect(verdicts { $0.agentReplies = 431 }["conversation.complete"] == false, "too few lines answered")
        // Interrupted after Grok's audio started: the heard part is a reply
        // of its own, so replies may exceed utterances.
        #expect(verdicts { $0.agentReplies = 452 }["conversation.complete"] == true, "a split cut mid-reply")
        // The conversation stalled: utterances left waiting at the end.
        #expect(verdicts { $0.unansweredUtterances = 1 }["conversation.complete"] == false, "a stall")
        #expect(
            verdicts {
                $0.agentReplies = 450
                $0.unansweredUtterances = 1
            }["conversation.complete"] == false, "the last utterance unanswered")
        #expect(verdicts { $0.failedTurns = 1 }["conversation.complete"] == false)
        #expect(verdicts { $0.lines = 0 }["conversation.complete"] == false)
        // The scripted path stays exact: one missing reply fails.
        #expect(
            verdicts {
                $0.transcript = .scripted
                $0.userUtterances = 480
                $0.agentReplies = 479
            }["conversation.complete"] == false)

        // voiceid.background: discards are counted, not required to be 0;
        // every score still decides right, and most lines reach Grok.
        #expect(verdicts { $0.gateDiscarded = 200 }["voiceid.background"] == true)
        #expect(verdicts { $0.gateCommitted = 431 }["voiceid.background"] == false)
        #expect(verdicts { $0.backgroundRejected = 409 }["voiceid.background"] == false)
        #expect(verdicts { $0.userAccepted = 959 }["voiceid.background"] == false)
        #expect(
            verdicts {
                $0.backgroundScores = 0
                $0.backgroundRejected = 0
            }["voiceid.background"] == false)

        // topics.count: only bounded above (1.5 × 79 + 1 = 120).
        #expect(verdicts { $0.topicBoundaries = 0 }["topics.count"] == true)
        #expect(verdicts { $0.topicBoundaries = 120 }["topics.count"] == true)
        #expect(verdicts { $0.topicBoundaries = 121 }["topics.count"] == false, "flapping")

        // Everything else is judged as on the scripted path.
        #expect(
            verdicts {
                $0.rollovers = 0
                $0.reseeds = 0
                $0.connections = 1
            }["realtime.rollover"] == false)

        let checks = SoakAnalysis.checks(samples: Self.samples(), outcome: Self.recognizedOutcome)
        let conversation = try Self.check("conversation.complete", checks)
        #expect(
            conversation.limit
                == "≥ 432 utterances and replies for 480 lines, none unanswered at the end, no failed turn")
        #expect(conversation.measured == "451 transcribed, 451 answered, 0 failed, 0 unanswered at the end")
        #expect(try Self.check("topics.count", checks).limit == "≤ 120")
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
        #expect(markdown.contains("renewal scheduled after 7.2 min of wall time"))
        #expect(markdown.contains("renewed 1 time."), "the renewals that happened, not the schedule")
        #expect(markdown.contains("Transcript: the script's word alignment"))
        let rows = markdown.components(separatedBy: "\n").filter {
            $0.hasPrefix("| ") && $0.dropFirst(2).first?.isNumber == true
        }
        #expect(rows.count == 121)
        #expect(markdown.contains("| Footprint | Heap |"))

        var withHeap = report
        withHeap.samples[0].heapInUseBytes = 20 << 20
        #expect(try SoakReport.decode(withHeap.jsonData()) == withHeap)
        #expect(withHeap.markdown.contains("| 40.8 MB | 20.0 MB |"))

        var unrenewed = report.outcome
        unrenewed.rollovers = 0
        let notRenewed = SoakReport(
            device: device, startedAt: report.startedAt, wallSeconds: 726, setup: report.setup, outcome: unrenewed,
            samples: report.samples)
        #expect(notRenewed.markdown.contains("renewed 0 times."))

        let recognized = SoakReport(
            device: device, startedAt: report.startedAt, wallSeconds: 7_300, setup: report.setup,
            outcome: Self.recognizedOutcome, samples: report.samples)
        #expect(recognized.passed)
        #expect(try SoakReport.decode(recognized.jsonData()) == recognized)
        #expect(recognized.markdown.contains("Transcript: recognized by the model"))

        var failing = report
        failing.checks[0].passed = false
        #expect(!failing.passed)
        #expect(failing.summary.hasSuffix("(failed: memory.slope)"))
        #expect(failing.markdown.contains("**FAIL**"))
    }
}
