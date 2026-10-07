import AVFAudio
import BlauCore

/// Converts mono Float32 audio at the hardware rate (48 kHz on the built-in
/// route, 16 or 24 kHz over Bluetooth HFP) to the pipeline's 16 kHz, as a
/// continuous stream.
///
/// Runs on the capture thread, never on the audio I/O thread:
/// `AVAudioConverter` allocates and takes locks internally. The converter
/// keeps its filter state between `process` calls, so chunk boundaries
/// don't produce clicks or lose samples; `flush` drains the filter's tail at
/// the end of a segment (before a gap or a graph rebuild) and resets it.
///
/// At 16 kHz input the resampler is a pass-through.
final class CaptureResampler {
    let inputSampleRate: Double
    let outputSampleRate: Double

    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer?
    /// Largest input slice handed to the converter per callback.
    private let inputCapacity: Int

    /// - Parameters:
    ///   - inputSampleRate: The hardware rate.
    ///   - outputSampleRate: The pipeline rate, 16 kHz.
    ///   - maximumChunk: The most input frames `process` gets at once; larger
    ///     inputs are fed in slices.
    init(
        inputSampleRate: Double,
        outputSampleRate: Double = Double(AudioFrame.captureSampleRate),
        maximumChunk: Int = 4_096
    ) throws(CaptureError) {
        precondition(inputSampleRate > 0 && outputSampleRate > 0, "Sample rates must be positive")
        precondition(maximumChunk > 0, "Chunks must hold at least one frame")
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputCapacity = maximumChunk

        guard inputSampleRate != outputSampleRate else {
            converter = nil
            inputBuffer = nil
            outputBuffer = nil
            return
        }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(maximumChunk)),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(
                    (Double(maximumChunk) * outputSampleRate / inputSampleRate).rounded(.up))
                    + 512
            )
        else {
            throw .converterUnavailable(inputSampleRate: inputSampleRate)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    /// Whether audio passes through unchanged.
    var isPassThrough: Bool { converter == nil }

    /// Converts `input` and calls `emit` with each piece of output, in order.
    /// Output can lag input by the filter's delay (a few milliseconds); it
    /// comes out with later input or with `flush`.
    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws(CaptureError) {
        guard !input.isEmpty else { return }
        guard let converter, let inputBuffer, let outputBuffer else {
            emit(input)
            return
        }
        var consumed = 0
        try convert(converter, input: inputBuffer, output: outputBuffer, emit: emit) { requested, status in
            let remaining = input.count - consumed
            guard remaining > 0 else {
                status.pointee = .noDataNow
                return nil
            }
            let count = min(remaining, Int(requested), self.inputCapacity)
            inputBuffer.floatChannelData![0].update(from: input.baseAddress! + consumed, count: count)
            inputBuffer.frameLength = AVAudioFrameCount(count)
            consumed += count
            status.pointee = .haveData
            return inputBuffer
        }
    }

    /// Emits what the filter still holds, then resets it for a new stream.
    func flush(emit: (UnsafeBufferPointer<Float>) -> Void) throws(CaptureError) {
        guard let converter, let inputBuffer, let outputBuffer else { return }
        defer { converter.reset() }
        try convert(converter, input: inputBuffer, output: outputBuffer, emit: emit) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    /// Drops the filter state without emitting it.
    func reset() {
        converter?.reset()
    }

    private func convert(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer,
        output: AVAudioPCMBuffer,
        emit: (UnsafeBufferPointer<Float>) -> Void,
        supply: @escaping AVAudioConverterInputBlock
    ) throws(CaptureError) {
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: supply)
            if output.frameLength > 0 {
                emit(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            switch status {
            case .haveData:
                // The output buffer filled up; there may be more.
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                converter.reset()
                throw .conversionFailed(SystemError(error ?? NSError(domain: "BlauAudio", code: -1)))
            @unknown default:
                return
            }
        }
    }
}
