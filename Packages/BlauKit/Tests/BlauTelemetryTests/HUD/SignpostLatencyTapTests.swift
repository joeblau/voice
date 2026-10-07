import Foundation
import Testing

@testable import BlauTelemetry

@Suite("LatencyWindow")
struct LatencyWindowTests {
    @Test func keepsTheLatestSamplesInARing() throws {
        var window = LatencyWindow(capacity: 3)
        #expect(window.stats == nil)
        for value in [100.0, 200, 300, 900] {
            window.add(milliseconds: value)
        }
        #expect(window.samples == [200, 300, 900])
        let stats = try #require(window.stats)
        #expect(stats.last == 900)
        #expect(stats.p50 == 300)
        #expect(abs(stats.p95 - 840) < 1e-9)
        #expect(stats.maximum == 900)
        #expect(abs(stats.mean - 466.666_666) < 1e-3)
        #expect(stats.windowCount == 3)
        #expect(stats.totalCount == 4)

        window.add(milliseconds: 50)
        window.add(milliseconds: 60)
        #expect(window.samples == [900, 50, 60])
    }

    @Test func ignoresValuesThatAreNotLatencies() {
        var window = LatencyWindow(capacity: 4)
        window.add(milliseconds: .nan)
        window.add(milliseconds: -1)
        window.add(milliseconds: .infinity)
        #expect(window.stats == nil)
        window.add(.milliseconds(12))
        #expect(window.stats?.last == 12)
    }

    @Test func statsFromDurations() throws {
        #expect(LatencyStats(last: nil, samples: []) == nil)
        let stats = try #require(
            LatencyStats(last: .milliseconds(30), samples: [.milliseconds(10), .milliseconds(30)], totalCount: 7))
        #expect(stats.last == 30)
        #expect(stats.p50 == 20)
        #expect(stats.totalCount == 7)
        #expect(stats.windowCount == 2)
    }
}

@Suite("SignpostLatencyTap")
struct SignpostLatencyTapTests {
    private func busyWait(milliseconds: Double) {
        let deadline = ContinuousClock.now + .microseconds(Int(milliseconds * 1_000))
        while ContinuousClock.now < deadline {}
    }

    @Test func recordsNothingWhileInactive() {
        let tap = SignpostLatencyTap()
        let base = RecordingSignpostBackend()
        let signposter = Signposter(category: .asr, backend: TappedSignpostBackend(base: base, tap: tap))
        signposter.withInterval(.asrChunk) { busyWait(milliseconds: 1) }
        #expect(tap.allStats().isEmpty)
        #expect(base.completedIntervals == ["asr.chunk"], "The base backend still sees the interval")
    }

    @Test func timesEveryCanonicalIntervalWhileActive() async throws {
        let tap = SignpostLatencyTap()
        tap.activate()
        let base = RecordingSignpostBackend()
        let signposter = Signposter(category: .asr, backend: TappedSignpostBackend(base: base, tap: tap))

        signposter.withInterval(.asrChunk) { busyWait(milliseconds: 4) }
        try await signposter.withInterval(.vadChunk) { try await Task.sleep(for: .milliseconds(3)) }
        let manual = signposter.beginInterval(.asrEndOfUtterance)
        busyWait(milliseconds: 2)
        manual.end(message: "eou")
        // Ad-hoc names reach Instruments but not the HUD.
        signposter.withInterval("asr.debugThing") { busyWait(milliseconds: 1) }

        #expect(base.completedIntervals == ["asr.chunk", "vad.chunk", "asr.eou", "asr.debugThing"])
        #expect(base.endMessages(of: "asr.eou") == ["eou"])
        #expect(tap.allStats().map(\.interval) == [.vadChunk, .asrChunk, .asrEndOfUtterance])

        let chunk = try #require(tap.stats(for: .asrChunk))
        #expect(chunk.totalCount == 1)
        #expect(chunk.last >= 4 && chunk.last < 50)
        let vad = try #require(tap.stats(for: .vadChunk))
        #expect(vad.last >= 3)
        let eou = try #require(tap.stats(for: .asrEndOfUtterance))
        #expect(eou.last >= 2 && eou.last < 50)
    }

    @Test func overlappingIntervalsAreTimedSeparately() throws {
        let tap = SignpostLatencyTap()
        tap.activate()
        let signposter = Signposter(
            category: .realtime, backend: TappedSignpostBackend(base: RecordingSignpostBackend(), tap: tap))
        let long = signposter.beginInterval(.realtimeTurn)
        busyWait(milliseconds: 2)
        let short = signposter.beginInterval(.realtimeTurn)
        busyWait(milliseconds: 2)
        short.end()
        busyWait(milliseconds: 2)
        long.end()
        long.end()  // Ending twice records once.

        let stats = try #require(tap.stats(for: .realtimeTurn))
        #expect(stats.totalCount == 2)
        #expect(stats.maximum >= 6)
        #expect(stats.p50 > 0)
    }

    @Test func timesIntervalsEvenWhenTheBaseIsOff() throws {
        let tap = SignpostLatencyTap()
        let base = RecordingSignpostBackend(isEnabled: false)
        let backend = TappedSignpostBackend(base: base, tap: tap)
        #expect(!backend.isEnabled)

        tap.activate()
        #expect(backend.isEnabled)
        let signposter = Signposter(category: .data, backend: backend)
        signposter.withInterval(.dbSave) { busyWait(milliseconds: 1) }
        signposter.event("data.event")
        #expect(base.records.isEmpty, "A disabled base backend is never called")
        #expect(tap.stats(for: .dbSave)?.totalCount == 1)
    }

    @Test func deactivatingKeepsTheSamplesAndActivatingClearsThem() {
        let tap = SignpostLatencyTap()
        tap.activate()
        tap.record(.memorySearch, nanoseconds: 5_000_000)
        tap.deactivate()
        #expect(!tap.isActive)
        #expect(tap.stats(for: .memorySearch)?.last == 5)
        tap.activate()
        #expect(tap.stats(for: .memorySearch) == nil)
    }

    @Test func intervalsBegunBeforeActivationAreNotTimed() {
        let tap = SignpostLatencyTap()
        let signposter = Signposter(
            category: .topics, backend: TappedSignpostBackend(base: RecordingSignpostBackend(), tap: tap))
        let interval = signposter.beginInterval(.topicsLabel)
        tap.activate()
        interval.end()
        #expect(tap.stats(for: .topicsLabel) == nil)
    }

    @Test func everyCanonicalNameMapsToItsSlot() {
        for interval in PipelineInterval.allCases {
            #expect(PipelineInterval.tapIndex(named: interval.name) == interval.tapIndex)
        }
        #expect(PipelineInterval.tapIndex(named: "asr.chunkX") == nil)
        #expect(PipelineInterval.tapIndex(named: "asr") == nil)
    }

    /// The shared signposters report to the shared tap: this is how every
    /// pipeline stage reaches the HUD.
    @Test func theSharedSignpostersReportToTheSharedTap() throws {
        #expect(Signposts.data.backend is TappedSignpostBackend)
        let tap = SignpostLatencyTap.shared
        let wasActive = tap.isActive
        tap.activate()
        defer { if !wasActive { tap.deactivate() } }
        Signposts.withInterval(.modelWarmUp) { busyWait(milliseconds: 1) }
        let stats = try #require(tap.stats(for: .modelWarmUp))
        #expect(stats.totalCount >= 1)
    }
}
