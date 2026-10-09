import Foundation
import Testing

@testable import BlauCore

@Suite("Host clock")
struct HostClockTests {
    @Test func ticksConvertAtTheMachineTimebase() {
        // A second of ContinuousClock time is a second of host time.
        let start = HostClock.now
        let wall = ContinuousClock.now
        while ContinuousClock.now - wall < .milliseconds(30) {}
        let measured = HostClock.elapsed(since: start)
        let reference = ContinuousClock.now - wall
        #expect(measured >= .milliseconds(30))
        #expect(abs((measured - reference).milliseconds) < 5)
    }

    @Test func aHostTimeInTheFutureIsZeroAgo() {
        let now = HostClock.now
        #expect(HostClock.elapsed(since: now + 1_000_000, now: now) == .zero)
        #expect(HostClock.elapsed(since: now, now: now) == .zero)
        #expect(HostClock.duration(ofTicks: 0) == .zero)
    }

    @Test func ticksAndDurationsRoundTrip() {
        for duration in [Duration.milliseconds(1), .milliseconds(20), .seconds(4), .seconds(3_600)] {
            let back = HostClock.duration(ofTicks: HostClock.ticks(for: duration))
            #expect(abs((back - duration).milliseconds) < 0.001, "\(duration)")
        }
        #expect(HostClock.ticks(for: .zero) == 0)
        #expect(HostClock.ticks(for: .seconds(-1)) == 0)
    }

    @Test func hugeSpansSaturateInsteadOfTrapping() {
        #expect(HostClock.duration(ofTicks: .max) >= .seconds(60 * 60 * 24 * 365))
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
