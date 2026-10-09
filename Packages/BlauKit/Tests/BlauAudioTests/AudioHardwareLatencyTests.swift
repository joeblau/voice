import BlauAudio
import BlauTelemetry
import Foundation
import Testing

@Suite("Audio hardware latency")
struct AudioHardwareLatencyTests {
    @Test func sessionReadingsBecomeMillisecondsAndTheRouteItsPortKinds() {
        let route = AudioRoute(
            inputs: [AudioPort(kind: .builtInMic, name: "iPhone Microphone", uid: "mic")],
            outputs: [AudioPort(kind: .builtInSpeaker, name: "Speaker", uid: "speaker")])
        let latency = AudioHardwareLatency(
            inputLatency: 0.0125, outputLatency: 0.0205, ioBufferDuration: 0.010_666, sampleRate: 48_000, route: route)
        #expect(latency.inputMilliseconds == 12.5)
        #expect(abs(latency.outputMilliseconds - 20.5) < 1e-9)
        #expect(abs(latency.ioBufferMilliseconds - 10.666) < 1e-9)
        #expect(latency.sampleRate == 48_000)
        // No device names: those can carry the owner's name.
        #expect(latency.route == "builtInMic -> builtInSpeaker")
    }

    @Test func readingsAnInactiveSessionCantMakeAreZero() {
        let latency = AudioHardwareLatency(
            inputLatency: -1, outputLatency: .nan, ioBufferDuration: 0, sampleRate: .nan, route: .none)
        #expect(latency.inputMilliseconds == 0)
        #expect(latency.outputMilliseconds == 0)
        #expect(latency.ioBufferMilliseconds == 0)
        #expect(latency.sampleRate == 0)
        #expect(latency.route == "none -> none")
    }
}
