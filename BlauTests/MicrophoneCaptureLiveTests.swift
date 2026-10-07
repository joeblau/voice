import AVFAudio
import BlauAudio
import BlauCore
import Foundation
import Testing

/// Runs the capture engine on the real voice-processing engine: the sink
/// node (or tap) on the VPIO input, the capture thread, the 16 kHz
/// conversion and the fan-out to three consumers. Needs microphone
/// permission (on a simulator: `xcrun simctl privacy <udid> grant
/// microphone com.joeblau.blau`), so it only runs with
/// `BLAU_DEVICE_TESTS=1`. See docs/audio.md.
@Suite(
    "MicrophoneCapture live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .timeLimit(.minutes(1))
)
struct MicrophoneCaptureLiveTests {
    @Test(arguments: MicrophoneCapture.InputMode.allCases)
    func threeConsumersReceiveTheSameLiveAudio(mode: MicrophoneCapture.InputMode) async throws {
        let capture = MicrophoneCapture(configuration: .init(inputMode: mode))
        let hub = capture.hub
        let controller = AudioSessionController.live()
        await controller.register(capture)

        let consumers = (0..<3).map { _ in
            Task {
                var frames: [AudioFrame] = []
                for await frame in hub.frames() {
                    frames.append(frame)
                }
                return frames
            }
        }
        let levels = Task {
            var count = 0
            for await _ in hub.levels() {
                count += 1
            }
            return count
        }

        #expect(await controller.start() == .running)
        let format = try #require(capture.inputFormat)
        #expect(format.isVoiceProcessed)

        // About one second of audio.
        let deadline = ContinuousClock.now + .seconds(5)
        while hub.nextSampleOffset < 16_000 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await controller.stop()
        capture.waitUntilDrained()
        hub.finish()

        let streams = await [consumers[0].value, consumers[1].value, consumers[2].value]
        #expect(streams[0] == streams[1])
        #expect(streams[1] == streams[2])
        let frames = streams[0]
        #expect(frames.reduce(0) { $0 + $1.sampleCount } >= 16_000)
        #expect(frames.allSatisfy { $0.sampleRate == 16_000 })
        // 20 ms frames; only the last frame of a capture segment can be short.
        #expect(frames.allSatisfy { $0.sampleCount <= 320 })
        #expect(frames.filter { $0.sampleCount == 320 }.count >= frames.count - Int(hub.statistics.segments))
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(next.sampleOffset == previous.nextSampleOffset)
            if let earlier = previous.hostTime, let later = next.hostTime {
                #expect(later > earlier)
            }
        }
        #expect(frames.first?.hostTime != nil)
        #expect(await levels.value > 0)

        let statistics = hub.statistics
        #expect(statistics.droppedBuffers == 0)
        #expect(statistics.conversionFailures == 0)
        // On the iOS 26.5 simulator the controller rebuilds the graph once
        // right after start (two segments); the stream must stay contiguous
        // across rebuilds, which the loop above checks.
        #expect(statistics.segments >= 1)
    }
}
