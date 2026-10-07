import BlauAudio
import BlauCore
import BlauTelemetry
import Testing

/// The acceptance criteria, sample by sample, against the two-minute delta
/// stream fixture.
@Suite("Streaming playback: two-minute delta stream", .timeLimit(.minutes(1)))
struct DeltaStreamPlaybackTests {
    static let fixture = DeltaStreamFixture.synthetic()

    static func makePlayer() -> StreamingAudioPlayer {
        StreamingAudioPlayer(clock: ManualClock(), signposter: .disabled(.audio))
    }

    @Test func fixtureIsTwoMinutesOfJitteredDeltas() {
        let fixture = Self.fixture
        #expect(fixture.duration == .seconds(120))
        #expect(fixture.deltas.count > 1_000)
        #expect(fixture.deltas.map(\.count).reduce(0, +) == fixture.samples.count)
        #expect(!fixture.samples.contains(0))
        // Arrivals are ordered but not evenly spaced.
        let arrivals = fixture.deltas.map(\.arrivalFrame)
        #expect(arrivals == arrivals.sorted())
        let gaps = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }
        #expect(Set(gaps).count > 100)
    }

    /// Acceptance: gapless playback of a recorded 2-minute delta stream.
    @Test func playsTheWholeStreamGaplessly() throws {
        let player = Self.makePlayer()
        var simulation = PlaybackSimulation(player: player, fixture: Self.fixture)
        try simulation.runToEnd()

        let expected = Self.fixture.floats
        let start = try #require(simulation.firstAudibleFrame)
        // Every sample, in order, back to back: nothing dropped, repeated or
        // inserted.
        #expect(Array(simulation.output[start..<(start + expected.count)]) == expected)
        #expect(simulation.output[(start + expected.count)...].allSatisfy { $0 == 0 })
        #expect(player.snapshot.underrunCount == 0)
        #expect(player.snapshot.state == .idle)

        // Playback began once the jitter buffer held 120 ms, not before.
        let preroll = Self.fixture.deltas.prefix { $0.start < 2_880 }.last!
        #expect(start >= preroll.arrivalFrame)
        #expect(start < preroll.arrivalFrame + 500)  // within the next render cycle

        let played = try #require(player.playedItem(for: simulation.item))
        #expect(played.playedFrames == Int64(expected.count))
        #expect(played.receivedFrames == Int64(expected.count))
        #expect(played.playedDuration == .seconds(120))
    }

    /// Acceptance: played-ms accurate to ±20 ms against the fixture,
    /// checked every few seconds through the stream and at a barge-in.
    @Test(arguments: [3_250, 17_001, 46_789, 89_999, 118_500])
    func playedMillisecondsMatchTheFixture(flushAtMilliseconds: Int) throws {
        let player = Self.makePlayer()
        var simulation = PlaybackSimulation(player: player, fixture: Self.fixture)
        let flushFrame = flushAtMilliseconds * 24

        var checkpoint = 2_000 * 24
        while checkpoint < flushFrame {
            try simulation.run(until: checkpoint)
            // Ground truth from the output itself: audible frames rendered.
            let heard = simulation.audibleFrameCount * 1000 / 24_000
            let reported = try #require(player.playedItem(for: simulation.item)).playedMilliseconds
            #expect(abs(reported - heard) <= 20, "at \(checkpoint / 24) ms: reported \(reported), heard \(heard)")
            checkpoint += 5_000 * 24
        }

        try simulation.run(until: flushFrame)
        let start = try #require(simulation.firstAudibleFrame)
        let result = player.flush()
        simulation.renderCycle(count: 480)

        let cut = try #require(result.current)
        #expect(cut.id == simulation.item)
        // What the fixture says was heard: from the start of playback to the
        // flush, plus the fade-out rendered after it.
        let heardFrames = simulation.audibleFrameCount
        let expectedMilliseconds = (flushFrame - start) * 1000 / 24_000
        #expect(abs(cut.playedMilliseconds - expectedMilliseconds) <= 20)
        #expect(abs(cut.playedMilliseconds - heardFrames * 1000 / 24_000) <= 20)
        #expect(cut.playedFrames == Int64(heardFrames))
        // The audible part of the output is exactly the fixture's prefix.
        #expect(
            Array(simulation.output[start..<(flushFrame)])
                == Array(Self.fixture.floats[0..<(flushFrame - start)])
        )
    }

    /// Acceptance: flush() → silence < 50 ms. At the render level it is
    /// the fade (5 ms) inside the very next cycle.
    @Test func flushSilencesTheNextCycleAfterAFiveMillisecondFade() throws {
        let player = Self.makePlayer()
        var simulation = PlaybackSimulation(player: player, fixture: Self.fixture)
        try simulation.run(until: 30 * 24_000)
        #expect(player.snapshot.state == .playing)
        #expect(player.snapshot.bufferedDuration > .zero)

        let flushFrame = simulation.now
        player.flush()
        // The rest of the stream keeps arriving (the server hasn't seen
        // response.cancel yet) and must be ignored.
        try simulation.run(until: flushFrame + 24_000)

        let after = Array(simulation.output[flushFrame...])
        let lastSound = try #require(after.lastIndex { $0 != 0 })
        #expect(lastSound < 120)  // 5 ms at 24 kHz
        #expect(lastSound * 1000 / 24_000 < 50)
        // A linear ramp down over what would have played next, not a hard cut.
        let start = try #require(simulation.firstAudibleFrame)
        let fade = lastSound + 1
        let next = Self.fixture.floats[(flushFrame - start)...].prefix(fade)
        for (index, sample) in next.enumerated() {
            #expect(after[index] == sample * (Float(fade - index) / Float(fade + 1)))
        }
        #expect(player.snapshot.state == .idle)
        #expect(player.snapshot.bufferedDuration == .zero)
        #expect(player.snapshot.level == .silent)
    }

    @Test func aStalledServerUnderrunsThenResumesWithoutLosingAudio() throws {
        var model = DeltaStreamFixture.ArrivalModel()
        model.stall = (atSecond: 20, milliseconds: 1_500)
        model.speed = 1.0...1.05
        let fixture = DeltaStreamFixture.synthetic(seconds: 40, seed: 99, model: model)
        let player = Self.makePlayer()
        var simulation = PlaybackSimulation(player: player, fixture: fixture)
        try simulation.runToEnd()

        #expect(player.snapshot.underrunCount >= 1)
        // Silence was inserted, but every sample still played, in order.
        let audible = simulation.output.filter { $0 != 0 }
        #expect(audible == fixture.floats)
        let played = try #require(player.playedItem(for: simulation.item))
        #expect(played.playedFrames == Int64(fixture.samples.count))
    }
}
