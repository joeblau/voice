import BlauTelemetry
import Dispatch
import Foundation
import os

/// One graph build's worth of capture: the producer the audio thread
/// writes into, and the capture thread that drains it.
///
/// A new segment starts on every `install(on:)` because the hardware
/// format can change between builds (48 kHz speaker → 16 kHz Bluetooth
/// HFP). Each segment's thread first waits for the previous segment's
/// thread to finish, so audio reaches the hub in order and only one thread
/// ever appends to it.
final class CaptureSegment: Sendable {
    let producer: CaptureProducer
    let inputSampleRate: Double
    private let finished = DispatchGroup()

    init(producer: CaptureProducer, inputSampleRate: Double) {
        self.producer = producer
        self.inputSampleRate = inputSampleRate
    }

    /// Starts the capture thread.
    ///
    /// - Parameters:
    ///   - previous: The segment before this one; its thread finishes first.
    ///   - pollInterval: How long the thread sleeps when no audio arrives
    ///     before checking whether the segment was closed.
    func start(
        hub: CaptureHub,
        signposter: Signposter,
        after previous: CaptureSegment?,
        pollInterval: DispatchTimeInterval = .milliseconds(250)
    ) {
        finished.enter()
        let thread = Thread { [self] in
            defer { finished.leave() }
            previous?.waitUntilFinished()
            run(hub: hub, signposter: signposter, pollInterval: pollInterval)
        }
        thread.name = "com.joeblau.blau.capture"
        // Above the UI, below the audio I/O thread.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the producer. The capture thread drains what is left, flushes
    /// and exits.
    func close() {
        producer.close()
    }

    /// Blocks until the capture thread has exited.
    func waitUntilFinished() {
        finished.wait()
    }

    /// Blocks until the capture thread has exited or `timeout` passes.
    ///
    /// - Returns: Whether it exited.
    func waitUntilFinished(timeout: DispatchTime) -> Bool {
        finished.wait(timeout: timeout) == .success
    }

    private func run(hub: CaptureHub, signposter: Signposter, pollInterval: DispatchTimeInterval) {
        hub.beginSegment()
        let consumer: CaptureConsumer
        do {
            consumer = try CaptureConsumer(
                producer: producer, hub: hub, inputSampleRate: inputSampleRate, signposter: signposter)
        } catch {
            // `MicrophoneCapture.install` creates a resampler for this rate
            // before starting the segment, so this shouldn't happen.
            Log.audio.fault("Capture thread couldn't start: \(error, privacy: .public)")
            return
        }
        while true {
            _ = producer.wake.wait(timeout: .now() + pollInterval)
            // Read `isClosed` before draining: everything written before the
            // close is visible, so the last drain gets all of it.
            let isClosed = producer.isClosed
            consumer.drain()
            if isClosed {
                consumer.finish()
                return
            }
        }
    }
}
