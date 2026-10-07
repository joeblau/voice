import AVFAudio
import BlauAudio
import BlauCore
import BlauTelemetry
import Testing

/// The player inside a real `AVAudioEngine`, rendered offline (manual
/// rendering mode) at 48 kHz stereo, the built-in route's hardware format.
/// This runs the actual `AVAudioSourceNode` and the main mixer's 24 → 48 kHz
/// conversion on the Mac, with no audio hardware, as fast as the CPU allows.
@Suite("StreamingAudioPlayer in AVAudioEngine", .serialized, .timeLimit(.minutes(2)))
struct PlaybackEngineTests {
    /// An engine in offline manual rendering mode with the player installed.
    final class OfflineEngine {
        static let sampleRate = 48_000
        let engine = AVAudioEngine()
        let player: StreamingAudioPlayer
        private let buffer: AVAudioPCMBuffer
        /// The left channel of everything rendered.
        private(set) var output: [Float] = []

        init(player: StreamingAudioPlayer) throws {
            self.player = player
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            try player.install(on: engine)
            try engine.start()
            buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        }

        deinit {
            engine.stop()
        }

        /// One 20 ms I/O cycle.
        func render(frames: Int = 960) throws {
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
            #expect(status == .success)
            let channel = try #require(buffer.floatChannelData)[0]
            output += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        }

        /// Renders cycles until `frame`, delivering fixture deltas as they
        /// arrive (their arrival times are at 24 kHz).
        func run(until frame: Int, fixture: DeltaStreamFixture, next: inout Int, item: PlaybackItemID) throws {
            while output.count < frame {
                while next < fixture.deltas.count, fixture.deltas[next].arrivalFrame * 2 <= output.count {
                    try player.enqueue(base64: fixture.deltas[next].base64, item: item)
                    next += 1
                    if next == fixture.deltas.count { player.finish(item) }
                }
                try render()
            }
        }

        var firstAudibleFrame: Int? { output.firstIndex { abs($0) > 0.01 } }
        var lastAudibleFrame: Int? { output.lastIndex { abs($0) > 0.01 } }
    }

    static let item = PlaybackItemID(itemID: "item_tone")

    static func makePlayer() -> StreamingAudioPlayer {
        StreamingAudioPlayer(clock: ManualClock(), signposter: .disabled(.audio))
    }

    /// Acceptance: gapless playback of a 2-minute delta stream, through the
    /// real node and sample-rate conversion.
    @Test func twoMinuteStreamPlaysWithoutAGapAtTheHardwareRate() throws {
        let fixture = DeltaStreamFixture.synthetic(seed: 0x70_4E, continuousTone: true)
        let host = try OfflineEngine(player: Self.makePlayer())
        var next = 0
        var checkpoints: [(reported: Int, heard: Int)] = []
        var checkpoint = 10 * 48_000
        while next < fixture.deltas.count || host.player.snapshot.state != .idle {
            try host.run(until: host.output.count + 960, fixture: fixture, next: &next, item: Self.item)
            if host.output.count >= checkpoint, let start = host.firstAudibleFrame {
                let reported = try #require(host.player.playedItem(for: Self.item)).playedMilliseconds
                checkpoints.append((reported, (host.output.count - start) * 1000 / 48_000))
                checkpoint += 10 * 48_000
            }
        }
        try host.render()

        let start = try #require(host.firstAudibleFrame)
        let end = try #require(host.lastAudibleFrame)
        // The tone is never quiet for a whole millisecond, so any window
        // without signal is a gap.
        var gaps = 0
        var window = start
        while window + 48 <= end {
            let peak = host.output[window..<(window + 48)].lazy.map(abs).max() ?? 0
            if peak < 0.1 { gaps += 1 }
            window += 48
        }
        #expect(gaps == 0)
        let playedMilliseconds = (end - start + 1) * 1000 / 48_000
        #expect(abs(playedMilliseconds - 120_000) <= 20)
        #expect(host.player.snapshot.underrunCount == 0)

        // Acceptance: played-ms within ±20 ms of what came out of the engine.
        #expect(checkpoints.count >= 10)
        for (reported, heard) in checkpoints {
            #expect(abs(reported - heard) <= 20, "reported \(reported) ms, heard \(heard) ms")
        }
    }

    /// Acceptance: flush() → silence < 50 ms, measured at the engine's
    /// output after resampling.
    @Test(arguments: [1_000, 2_510, 7_777])
    func flushSilencesTheEngineOutputWithinFiftyMilliseconds(afterMilliseconds: Int) throws {
        let fixture = DeltaStreamFixture.synthetic(seconds: 10, seed: 3, continuousTone: true)
        let host = try OfflineEngine(player: Self.makePlayer())
        var next = 0
        try host.run(until: afterMilliseconds * 48, fixture: fixture, next: &next, item: Self.item)
        let flushFrame = host.output.count
        let start = try #require(host.firstAudibleFrame)
        #expect(host.player.snapshot.isSpeaking)

        let result = host.player.flush()
        // Keep rendering while late deltas keep arriving.
        try host.run(until: flushFrame + 500 * 48, fixture: fixture, next: &next, item: Self.item)

        let lastSound = try #require(host.output[flushFrame...].lastIndex { abs($0) > 0.001 })
        let silenceAfter = Double(lastSound - flushFrame + 1) / 48
        #expect(silenceAfter < 50, "silent after \(silenceAfter) ms")

        let heard = (flushFrame - start) * 1000 / 48_000
        let reported = try #require(result.current).playedMilliseconds
        #expect(abs(reported - heard) <= 20, "reported \(reported) ms, heard \(heard) ms")
    }

    @Test func uninstallDetachesTheNodeAndReinstallResumesTheQueue() throws {
        let player = Self.makePlayer()
        let host = try OfflineEngine(player: player)
        let attached = host.engine.attachedNodes.count
        player.enqueue(samples: [Float](repeating: 0.25, count: 24_000), item: Self.item)
        try host.render()
        try host.render()  // playing: a full second is queued
        #expect(host.output.suffix(480).allSatisfy { abs($0 - 0.25) < 0.001 })

        host.engine.stop()
        player.uninstall(from: host.engine)
        #expect(host.engine.attachedNodes.count == attached - 1)
        #expect(player.snapshot.level == .silent)
        player.uninstall(from: host.engine)  // idempotent

        try player.install(on: host.engine)
        try host.engine.start()
        #expect(host.engine.attachedNodes.count == attached)
        let before = try #require(player.playedItem(for: Self.item)).playedFrames
        try host.render()
        try host.render()
        let after = try #require(player.playedItem(for: Self.item)).playedFrames
        #expect(after > before)
        // Same level as before the rebuild: a reconnected mono mixer input
        // would come back 3 dB quieter (0.177).
        #expect(host.output.suffix(480).allSatisfy { abs($0 - 0.25) < 0.001 })
    }
}
