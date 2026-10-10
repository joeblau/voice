import BlauCore
import BlauTelemetry
import BlauTopics
import Foundation
import Testing

/// The tap-to-expand measurement behind the 100 ms target (#58).
@Suite("TopicExpansionTimer")
@MainActor
struct TopicExpansionTimerTests {
    private let clock = ManualClock()
    private let signposts = RecordingSignpostBackend()

    private func makeTimer(capacity: Int = 50) -> TopicExpansionTimer {
        TopicExpansionTimer(
            clock: clock, signposter: Signposter(category: .ui, backend: signposts), capacity: capacity)
    }

    @Test func measuresFromTheTapToTheDetailAppearing() {
        let timer = makeTimer()
        let topic = UUID()
        timer.began(topic)
        #expect(timer.isMeasuring(topic))
        #expect(signposts.openIntervals == ["timeline.expand"])

        clock.advance(by: .milliseconds(42))
        #expect(timer.appeared(topic) == .milliseconds(42))
        #expect(timer.last == .init(topicID: topic, latency: .milliseconds(42)))
        #expect(timer.recent == [.milliseconds(42)])
        #expect(!timer.isMeasuring(topic))
        #expect(signposts.completedIntervals == ["timeline.expand"])
        #expect(signposts.endMessages(of: "timeline.expand") == ["expanded"])
    }

    /// A topic that was already open and scrolls back into view appears
    /// again without a tap: nothing to measure.
    @Test func anAppearanceWithoutATapIsntMeasured() {
        let timer = makeTimer()
        #expect(timer.appeared(UUID()) == nil)
        #expect(timer.last == nil)
        #expect(signposts.completedIntervals.isEmpty)
    }

    @Test func compressingBeforeItAppearsEndsTheIntervalWithoutASample() {
        let timer = makeTimer()
        let topic = UUID()
        timer.began(topic)
        timer.cancelled(topic)
        #expect(timer.appeared(topic) == nil)
        #expect(timer.recent.isEmpty)
        #expect(signposts.endMessages(of: "timeline.expand") == ["compressed"])
    }

    @Test func aSecondTapRestartsTheMeasurement() {
        let timer = makeTimer()
        let topic = UUID()
        timer.began(topic)
        clock.advance(by: .milliseconds(300))
        timer.began(topic)
        clock.advance(by: .milliseconds(20))
        #expect(timer.appeared(topic) == .milliseconds(20))
        #expect(signposts.endMessages(of: "timeline.expand") == ["superseded", "expanded"])
    }

    @Test func severalTopicsAreMeasuredIndependently() {
        let timer = makeTimer()
        let first = UUID()
        let second = UUID()
        timer.began(first)
        clock.advance(by: .milliseconds(10))
        timer.began(second)
        clock.advance(by: .milliseconds(15))
        #expect(timer.appeared(second) == .milliseconds(15))
        #expect(timer.appeared(first) == .milliseconds(25))
        #expect(timer.slowest == .milliseconds(25))
    }

    @Test func keepsTheRecentSamples() {
        let timer = makeTimer(capacity: 3)
        for milliseconds in [10, 20, 90, 30, 40] {
            let topic = UUID()
            timer.began(topic)
            clock.advance(by: .milliseconds(milliseconds))
            timer.appeared(topic)
        }
        #expect(timer.recent == [.milliseconds(90), .milliseconds(30), .milliseconds(40)])
        #expect(timer.slowest == .milliseconds(90))
    }

    @Test func equalLatenciesHaveDistinctMeasurementsAfterTheHistoryIsFull() {
        let timer = makeTimer(capacity: 1)
        let topic = UUID()
        #expect(timer.measurementCount == 0)
        for count in 1...3 {
            timer.began(topic)
            clock.advance(by: .milliseconds(42))
            timer.appeared(topic)
            #expect(timer.measurementCount == count)
            #expect(timer.last?.latency == .milliseconds(42))
            #expect(timer.recent == [.milliseconds(42)])
        }
        timer.began(topic)
        timer.cancelled(topic)
        #expect(timer.appeared(topic) == nil)
        #expect(timer.measurementCount == 3)
    }

    @Test func topicsThatGoAwayStopBeingMeasured() {
        let timer = makeTimer()
        let kept = UUID()
        let merged = UUID()
        timer.began(kept)
        timer.began(merged)
        timer.retain(only: [kept])
        #expect(timer.isMeasuring(kept))
        #expect(!timer.isMeasuring(merged))
        #expect(signposts.endMessages(of: "timeline.expand") == ["removed"])
    }

    @Test func theTargetIsAHundredMilliseconds() {
        #expect(TopicExpansionTimer.target == .milliseconds(100))
    }
}
