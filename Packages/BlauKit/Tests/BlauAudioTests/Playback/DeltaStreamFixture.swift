import BlauAudio
import BlauCore
import Foundation

/// A deterministic stand-in for a recorded `response.output_audio.delta`
/// stream: speech-like 24 kHz PCM16 audio cut into base64 deltas, each with
/// the time it reaches the client.
///
/// The arrival model follows how a speech-to-speech server streams: audio
/// is generated somewhat faster than real time (the speed varies per
/// delta), each delta becomes available once all of its audio exists, and
/// network latency adds jitter with occasional spikes. WebSocket delivery is
/// ordered, so arrivals never go backwards.
///
/// No real Grok recording is committed (it would need xAI credentials, and
/// two minutes of PCM16 is ~5.8 MB). Every value comes from a seeded
/// generator, so a fixture is identical on every run and every machine.
/// `RecordedDeltaStream` replays a real capture when one is supplied.
struct DeltaStreamFixture {
    struct Delta {
        /// When the delta reaches the client, in frames of the stream's
        /// sample rate since the request was sent.
        var arrivalFrame: Int
        /// Index of its first sample in `samples`.
        var start: Int
        var count: Int
        var base64: String
    }

    static let sampleRate = 24_000

    /// The whole response, PCM16. No sample is zero, so a zero in the
    /// player's output is always inserted silence.
    var samples: [Int16]
    var deltas: [Delta]

    var duration: Duration { .samples(Int64(samples.count), sampleRate: Self.sampleRate) }

    /// The samples as the player outputs them.
    var floats: [Float]

    struct ArrivalModel {
        /// Generation speed relative to real time, drawn per delta.
        var speed: ClosedRange<Double> = 1.1...2.0
        /// Delta length in milliseconds, drawn per delta.
        var deltaMilliseconds: ClosedRange<Int> = 20...100
        /// Network latency in milliseconds, drawn per delta.
        var latencyMilliseconds: ClosedRange<Int> = 20...60
        /// Chance of a latency spike per delta, and its extra delay.
        var spikeProbability = 0.01
        var spikeMilliseconds = 60
        /// Where a stall begins (seconds of audio) and how long the server
        /// pauses there, in milliseconds. Models a server-side hiccup.
        var stall: (atSecond: Int, milliseconds: Int)?
    }

    /// - Parameters:
    ///   - seconds: Audio length.
    ///   - seed: Generator seed; the same seed gives the same fixture.
    ///   - model: How deltas are sized and when they arrive.
    ///   - continuousTone: A steady 440 Hz tone instead of speech-like audio,
    ///     so a gap shows up even after resampling.
    static func synthetic(
        seconds: Int = 120,
        seed: UInt64 = 0xB1A0,
        model: ArrivalModel = ArrivalModel(),
        continuousTone: Bool = false
    ) -> DeltaStreamFixture {
        var random = SplitMix64(seed: seed)
        let total = seconds * sampleRate
        let samples = continuousTone ? tone(count: total) : speechLike(count: total, random: &random)

        var deltas: [Delta] = []
        var start = 0
        var generatedSeconds = 0.0
        var lastArrival = 0
        var stall = model.stall
        while start < total {
            let milliseconds = Int(random.next(in: model.deltaMilliseconds))
            let count = min(total - start, milliseconds * sampleRate / 1000)
            let speed = random.next(in: model.speed)
            generatedSeconds += Double(count) / Double(sampleRate) / speed
            if let pause = stall, start >= pause.atSecond * sampleRate {
                generatedSeconds += Double(pause.milliseconds) / 1000
                stall = nil
            }
            var latency = Double(random.next(in: model.latencyMilliseconds)) / 1000
            if random.nextUnit() < model.spikeProbability {
                latency += Double(model.spikeMilliseconds) / 1000
            }
            let arrival = max(lastArrival, Int((generatedSeconds + latency) * Double(sampleRate)))
            lastArrival = arrival

            let bytes = samples[start..<(start + count)].withUnsafeBufferPointer { Data(buffer: $0) }
            deltas.append(Delta(arrivalFrame: arrival, start: start, count: count, base64: bytes.base64EncodedString()))
            start += count
        }
        return DeltaStreamFixture(samples: samples, deltas: deltas, floats: PCM16Decoder.floats(from: samples))
    }

    /// Voiced "syllables" with varying pitch, three harmonics and a smooth
    /// envelope, separated by short low-level pauses.
    private static func speechLike(count: Int, random: inout SplitMix64) -> [Int16] {
        var samples = [Int16](repeating: 0, count: count)
        var index = 0
        var phase = 0.0
        while index < count {
            let isPause = random.nextUnit() < 0.2
            let length = min(count - index, Int(random.next(in: isPause ? 40...250 : 80...300)) * sampleRate / 1000)
            let pitch = random.next(in: 95.0...240.0)
            let loudness = random.next(in: 0.15...0.6)
            for offset in 0..<length {
                var value: Double
                if isPause {
                    value = (random.nextUnit() - 0.5) * 0.002
                } else {
                    let envelope = sin(Double.pi * Double(offset) / Double(length))
                    phase += 2 * Double.pi * pitch / Double(sampleRate)
                    value = loudness * envelope * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75
                    value += (random.nextUnit() - 0.5) * 0.002
                }
                var sample = Int16(clamping: Int((value * 32_767).rounded()))
                if sample == 0 { sample = 1 }
                samples[index + offset] = sample
            }
            index += length
        }
        return samples
    }

    private static func tone(count: Int) -> [Int16] {
        (0..<count).map { index in
            let value = 0.5 * sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            let sample = Int16(clamping: Int((value * 32_767).rounded()))
            return sample == 0 ? 1 : sample
        }
    }
}

/// A small, fast, seedable generator (SplitMix64), so fixtures don't depend
/// on the platform's random number generator.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
