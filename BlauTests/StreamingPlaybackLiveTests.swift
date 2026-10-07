import AVFAudio
import BlauAudio
import BlauCore
import Foundation
import Testing

/// The playback node on the real voice-processing engine, driven by the
/// live `AudioSessionController`. The sample-accurate checks run on the Mac
/// (`Packages/BlauKit/Tests/BlauAudioTests/Playback`); this proves the node
/// renders through VPIO in real time and stops on flush.
///
/// Needs microphone permission (the controller starts capture too), so it
/// only runs with `BLAU_DEVICE_TESTS=1`. See docs/audio.md.
@Suite(
    "StreamingAudioPlayer live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .timeLimit(.minutes(1))
)
struct StreamingPlaybackLiveTests {
    static let item = PlaybackItemID(itemID: "item_live")

    /// A quiet 440 Hz tone, as PCM16 bytes at 24 kHz.
    static func tone(milliseconds: Int) -> Data {
        let samples = (0..<(milliseconds * 24)).map { index in
            Int16(3_000 * sin(2 * Double.pi * 440 * Double(index) / 24_000))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func playsInRealTimeAndFlushesOnTheVoiceProcessingEngine() async throws {
        let player = StreamingAudioPlayer()
        let controller = AudioSessionController.live()
        await controller.register(player)
        #expect(await controller.start() == .running)

        let clock = ContinuousClock()
        let started = clock.now
        let audio = Self.tone(milliseconds: 2_000)
        // 100 ms deltas, delivered a little faster than real time.
        for offset in stride(from: 0, to: audio.count, by: 4_800) {
            player.enqueue(pcm16: audio[offset..<min(offset + 4_800, audio.count)], item: Self.item)
            try await Task.sleep(for: .milliseconds(80))
        }
        let elapsed = started.duration(to: clock.now)
        let played = try #require(player.playedItem(for: Self.item))
        #expect(player.snapshot.isSpeaking)
        #expect(player.snapshot.level.rms > 0)
        // Real-time pacing: about what has elapsed since the jitter buffer filled.
        let error = played.playedDuration - (elapsed - .milliseconds(120))
        #expect(
            error > .milliseconds(-150) && error < .milliseconds(150), "played \(played.playedDuration) in \(elapsed)")

        let cut = player.flush()
        let atFlush = try #require(cut.current).playedFrames
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.playedItem(for: Self.item)?.playedFrames == atFlush)
        #expect(player.snapshot.state == .idle)
        #expect(player.snapshot.level == .silent)

        await controller.stop()
    }
}
