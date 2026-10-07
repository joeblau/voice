import BlauTelemetry
import Foundation
import Testing

/// Emits every canonical interval through the real `os` backend so a trace
/// can confirm they reach Instruments. Off by default; run it with
/// `scripts/verify-signposts.sh`, which records an os_signpost trace around
/// it and checks every interval name shows up.
@Suite(
    "Signpost smoke run",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_SIGNPOST_SMOKE"] == "1")
)
struct SignpostSmokeTests {
    /// Intervals per name, so a dropped record would show as a short count.
    static let repetitions = 3

    @Test func emitEveryCanonicalInterval() async throws {
        for _ in 0..<Self.repetitions {
            for interval in PipelineInterval.allCases {
                Signposts.withInterval(interval) { busyWait(milliseconds: 2) }
                try await Signposts.withInterval(interval) { try await Task.sleep(for: .milliseconds(2)) }
                let manual = Signposts.beginInterval(interval)
                busyWait(milliseconds: 1)
                manual.end()
            }
        }
        for category in LogCategory.allCases {
            Signposts.event("smoke.event", category: category)
        }
    }

    private func busyWait(milliseconds: Int) {
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while ContinuousClock.now < deadline {}
    }
}
