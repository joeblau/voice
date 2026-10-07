import BlauCore
import Foundation
import Testing

@Suite("TimeRange")
struct TimeRangeTests {
    private func range(_ start: Int, _ end: Int) -> TimeRange {
        TimeRange(start: .milliseconds(start), end: .milliseconds(end))
    }

    @Test func durationAndEmptiness() {
        #expect(range(100, 350).duration == .milliseconds(250))
        #expect(!range(100, 350).isEmpty)
        #expect(TimeRange.instant(.seconds(1)).isEmpty)
        #expect(TimeRange(start: .seconds(1), duration: .seconds(2)) == range(1_000, 3_000))
    }

    @Test func validatingInitRejectsReversedBounds() {
        #expect(TimeRange(validatingStart: .seconds(2), end: .seconds(1)) == nil)
        #expect(TimeRange(validatingStart: .seconds(1), end: .seconds(1)) == .instant(.seconds(1)))
    }

    @Test func containsInstantsHalfOpen() {
        let r = range(100, 200)
        #expect(r.contains(.milliseconds(100)))
        #expect(r.contains(.milliseconds(199)))
        #expect(!r.contains(.milliseconds(200)))
        #expect(!r.contains(.milliseconds(99)))
        #expect(!TimeRange.instant(.zero).contains(.zero))
    }

    @Test func containsRanges() {
        #expect(range(0, 100).contains(range(10, 90)))
        #expect(range(0, 100).contains(range(0, 100)))
        #expect(!range(0, 100).contains(range(50, 150)))
    }

    @Test func overlapIsStrict() {
        #expect(range(0, 100).overlaps(range(50, 150)))
        #expect(range(50, 150).overlaps(range(0, 100)))
        #expect(!range(0, 100).overlaps(range(100, 200)), "touching ranges don't overlap")
        #expect(!range(0, 100).overlaps(.instant(.milliseconds(50))), "empty ranges overlap nothing")
    }

    @Test func intersectionAndUnion() {
        #expect(range(0, 100).intersection(range(50, 150)) == range(50, 100))
        #expect(range(0, 100).intersection(range(100, 150)) == nil)
        #expect(range(0, 100).union(range(200, 300)) == range(0, 300))
        #expect(range(50, 60).union(range(0, 100)) == range(0, 100))
    }

    @Test func offset() {
        #expect(range(100, 200).offset(by: .milliseconds(50)) == range(150, 250))
        #expect(range(100, 200).offset(by: .milliseconds(-100)) == range(0, 100))
    }

    @Test func roundTripsThroughJSON() throws {
        let original = TimeRange(start: .milliseconds(1_234), end: .nanoseconds(5_678_901_234))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TimeRange.self, from: data) == original)
    }

    @Test func decodingRejectsReversedBounds() throws {
        struct Raw: Encodable {
            let start: Duration
            let end: Duration
        }
        let data = try JSONEncoder().encode(Raw(start: .seconds(5), end: .seconds(1)))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimeRange.self, from: data)
        }
    }
}

@Suite("Duration sample conversions")
struct DurationSampleTests {
    @Test func sampleDurationsAreExact() {
        #expect(Duration.samples(16_000, sampleRate: 16_000) == .seconds(1))
        #expect(Duration.samples(5_120, sampleRate: 16_000) == .milliseconds(320))
        #expect(Duration.samples(0, sampleRate: 16_000) == .zero)
        #expect(Duration.samples(48_000 * 3_600, sampleRate: 48_000) == .seconds(3_600))
    }

    @Test func inexactSampleDurationsRoundUpToTheNextAttosecond() {
        // 1 / 24 000 s = 41 666 666 666 666.67 attoseconds.
        let duration = Duration.samples(1, sampleRate: 24_000)
        #expect(duration == Duration(secondsComponent: 0, attosecondsComponent: 41_666_666_666_667))
    }

    @Test func sampleDurationsDontDriftOverLongSessions() {
        // Two hours of 320 ms chunks: summing chunk durations equals the
        // duration of the total sample count.
        let chunk = Duration.samples(5_120, sampleRate: 16_000)
        let chunks = 2 * 60 * 60 * 1_000 / 320
        #expect(chunk * chunks == .samples(Int64(5_120 * chunks), sampleRate: 16_000))
        #expect(chunk * chunks == .seconds(7_200))
    }

    @Test(arguments: [8_000, 16_000, 22_050, 24_000, 44_100, 48_000])
    func sampleCountInvertsSampleDuration(sampleRate: Int) {
        for count: Int64 in [0, 1, 159, 5_120, 1_234_567, 115_200_000] {
            #expect(Duration.samples(count, sampleRate: sampleRate).sampleCount(sampleRate: sampleRate) == count)
        }
    }

    @Test func sampleCountRoundsTowardZero() {
        #expect(Duration.microseconds(99).sampleCount(sampleRate: 16_000) == 1)
        #expect(Duration.microseconds(62).sampleCount(sampleRate: 16_000) == 0)
    }

    @Test func timeInterval() {
        #expect(Duration.milliseconds(1_500).timeInterval == 1.5)
        #expect(Duration.seconds(-2).timeInterval == -2)
    }
}

@Suite("AudioFrame")
struct AudioFrameTests {
    @Test func defaultsToTheCaptureSampleRate() {
        #expect(AudioFrame.captureSampleRate == 16_000)
        #expect(AudioFrame(samples: [], sampleOffset: 0).sampleRate == 16_000)
    }

    @Test func positionAndDurationComeFromSampleIndices() {
        let frame = AudioFrame(samples: Array(repeating: 0, count: 5_120), sampleOffset: 16_000)
        #expect(frame.sampleCount == 5_120)
        #expect(frame.duration == .milliseconds(320))
        #expect(frame.timeRange == TimeRange(start: .seconds(1), end: .milliseconds(1_320)))
        #expect(frame.nextSampleOffset == 21_120)
    }

    @Test func consecutiveFramesTile() {
        let first = AudioFrame(samples: Array(repeating: 0, count: 333), sampleRate: 24_000, sampleOffset: 0)
        let second = AudioFrame(
            samples: Array(repeating: 0, count: 333), sampleRate: 24_000, sampleOffset: first.nextSampleOffset)
        #expect(first.timeRange.end == second.timeRange.start)
    }

    @Test func levels() {
        let frame = AudioFrame(samples: [0.5, -0.5, 0.5, -0.5], sampleOffset: 0)
        #expect(abs(frame.rms - 0.5) < 1e-6)
        #expect(frame.peak == 0.5)

        let spike = AudioFrame(samples: [0, -0.9, 0.1], sampleOffset: 0)
        #expect(spike.peak == 0.9)
    }

    @Test func hostTimeIsOptionalAndPartOfEquality() {
        #expect(AudioFrame(samples: [0], sampleOffset: 0).hostTime == nil)
        let stamped = AudioFrame(samples: [0], sampleOffset: 0, hostTime: 1_234)
        #expect(stamped.hostTime == 1_234)
        #expect(stamped != AudioFrame(samples: [0], sampleOffset: 0))
    }

    @Test func emptyFrameHasZeroLevels() {
        let frame = AudioFrame(samples: [], sampleOffset: 42)
        #expect(frame.isEmpty)
        #expect(frame.rms == 0)
        #expect(frame.peak == 0)
        #expect(frame.duration == .zero)
        #expect(frame.timeRange.isEmpty)
    }
}
