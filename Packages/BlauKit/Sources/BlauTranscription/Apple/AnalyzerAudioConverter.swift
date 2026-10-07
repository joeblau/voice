import AVFAudio
import BlauCore

/// Turns 16 kHz mono `AudioFrame`s into `AVAudioPCMBuffer`s in the format
/// the speech analyzer asks for (`SpeechAnalyzer.bestAvailableAudioFormat`,
/// 16 kHz mono 16-bit integer on current systems).
///
/// Mono at 16 kHz in 32-bit float or 16-bit integer is converted directly;
/// anything else goes through an `AVAudioConverter`, which keeps its
/// resampler state across frames so a stream converts without seams.
///
/// Not thread-safe: one converter per stream, used from one actor.
final class AnalyzerAudioConverter {
    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    enum ConversionError: Error, Equatable {
        case unsupportedFormat
        case bufferAllocationFailed
        case conversionFailed(String)
    }

    init(outputFormat: AVAudioFormat) throws {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFrame.captureSampleRate), channels: 1,
                interleaved: false)
        else { throw ConversionError.unsupportedFormat }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if Self.convertsDirectly(to: outputFormat) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ConversionError.unsupportedFormat
            }
            self.converter = converter
        }
    }

    /// Whether `format` is mono 16 kHz float or 16-bit integer, which is
    /// copied without an `AVAudioConverter`.
    static func convertsDirectly(to format: AVAudioFormat) -> Bool {
        format.channelCount == 1 && format.sampleRate == Double(AudioFrame.captureSampleRate)
            && (format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16)
    }

    /// `frame`'s samples in `outputFormat`.
    func buffer(for frame: AudioFrame) throws -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(frame.sampleCount)
        if converter == nil {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(count, 1)) else {
                throw ConversionError.bufferAllocationFailed
            }
            output.frameLength = count
            frame.samples.withUnsafeBufferPointer { samples in
                if outputFormat.commonFormat == .pcmFormatInt16, let channel = output.int16ChannelData?[0] {
                    for index in 0..<samples.count {
                        let clamped = min(max(samples[index], -1), 1)
                        channel[index] = Int16((clamped * Float(Int16.max)).rounded())
                    }
                } else if let channel = output.floatChannelData?[0] {
                    for index in 0..<samples.count {
                        channel[index] = samples[index]
                    }
                }
            }
            return output
        }

        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: max(count, 1)) else {
            throw ConversionError.bufferAllocationFailed
        }
        input.frameLength = count
        if let channel = input.floatChannelData?[0] {
            frame.samples.withUnsafeBufferPointer { samples in
                for index in 0..<samples.count {
                    channel[index] = samples[index]
                }
            }
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.bufferAllocationFailed
        }
        let source = OneShotInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            source.next(inputStatus)
        }
        if status == .error {
            throw ConversionError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        return output
    }
}

/// Hands one buffer to an `AVAudioConverter` input block, then reports
/// "no data for now" so the converter keeps its state for the next frame.
/// The block runs synchronously inside `convert(to:error:withInputFrom:)`.
private final class OneShotInput {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
