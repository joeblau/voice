import BlauTelemetry
import Testing
import os

private struct ProbeError: Error, Equatable {}

/// A non-`Sendable` value, to check that async intervals run on the caller's
/// isolation and can hand such values back.
private final class Box {
    var value = 0
}

/// Every helper must behave exactly like running the body directly when
/// signposting is off: same result, same error, no crash.
@Suite("Signposter, signposting disabled")
struct DisabledSignposterTests {
    /// Both ways of being disabled: the real os backend over
    /// `OSSignposter.disabled`, and a backend that reports itself disabled.
    static let disabled: [Signposter] =
        LogCategory.allCases.map { Signposter.disabled($0) }
        + [Signposter(category: .audio, backend: OSSignpostBackend(.disabled))]

    @Test func osDisabledBackendReportsDisabled() {
        #expect(!OSSignpostBackend.disabled.isEnabled)
        #expect(!Signposter.disabled(.asr).isEnabled)
    }

    @Test(arguments: disabled)
    func syncIntervalReturnsTheBodysResult(signposter: Signposter) {
        var ran = false
        let value = signposter.withInterval("test.sync") {
            ran = true
            return 42
        }
        #expect(ran)
        #expect(value == 42)
    }

    @Test(arguments: disabled)
    func syncIntervalRethrows(signposter: Signposter) {
        #expect(throws: ProbeError()) {
            try signposter.withInterval("test.throw") { () throws(ProbeError) -> Int in throw ProbeError() }
        }
    }

    @Test(arguments: disabled)
    func asyncIntervalReturnsTheBodysResult(signposter: Signposter) async {
        let value = await signposter.withInterval("test.async") {
            await Task.yield()
            return "done"
        }
        #expect(value == "done")
    }

    @Test(arguments: disabled)
    func asyncIntervalRethrows(signposter: Signposter) async {
        await #expect(throws: ProbeError()) {
            try await signposter.withInterval("test.asyncThrow") { () async throws(ProbeError) -> Int in
                await Task.yield()
                throw ProbeError()
            }
        }
    }

    @Test(arguments: disabled)
    func canonicalIntervalsNestAndOverlap(signposter: Signposter) async {
        let total = await withTaskGroup(of: Int.self) { group in
            for interval in PipelineInterval.allCases {
                group.addTask {
                    await signposter.withInterval(interval) {
                        await Task.yield()
                        return signposter.withInterval(interval) { 1 }
                    }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(total == PipelineInterval.allCases.count)
    }

    @Test(arguments: disabled)
    func manualIntervalsAndEventsAreNoOps(signposter: Signposter) {
        let interval = signposter.beginInterval(.realtimeFirstAudio)
        #expect(!interval.isEnded)
        signposter.event("test.event")
        #expect(interval.end())
        #expect(!interval.end())
        #expect(interval.isEnded)
    }

    @Test func recordingBackendThatIsDisabledSeesNothing() async throws {
        let backend = RecordingSignpostBackend(isEnabled: false)
        let signposter = Signposter(category: .memory, backend: backend)

        _ = signposter.withInterval(.memoryEmbed) { 1 }
        _ = await signposter.withInterval(.memorySearch) {
            await Task.yield()
            return 2
        }
        signposter.beginInterval("test.manual").end()
        signposter.event("test.event")

        #expect(backend.records.isEmpty)
    }
}

/// The helpers against the real `os` backend. Under `swift test` nothing is
/// usually recording, but the calls go through `os_signpost` either way.
@Suite("Signposter, os backend")
struct OSSignposterTests {
    @Test(arguments: LogCategory.allCases)
    func sharedSignpostersEmitWithoutCrashing(category: LogCategory) async throws {
        let signposter = Signposts.signposter(for: category)
        #expect(signposter.category == category)

        _ = signposter.withInterval("test.sync") { 1 }
        _ = await signposter.withInterval("test.async") {
            await Task.yield()
            return 2
        }
        #expect(throws: ProbeError.self) {
            try signposter.withInterval("test.throw") { () throws(ProbeError) in throw ProbeError() }
        }
        signposter.event("test.event")
        let interval = signposter.beginInterval("test.manual")
        #expect(interval.end())
    }

    @Test func canonicalIntervalsRouteToTheirCategory() async throws {
        for interval in PipelineInterval.allCases {
            let value = Signposts.withInterval(interval) { interval.name.description }
            #expect(value == interval.name.description)
            _ = await Signposts.withInterval(interval) { await Task.yield() }
            let manual = Signposts.beginInterval(interval)
            #expect(manual.category == interval.category)
            #expect(manual.name.description == interval.name.description)
            manual.end()
        }
        Signposts.event("test.event", category: .ui)
    }

    @Test func staticSignpostersMatchTheirCategories() {
        #expect(Signposts.audio.category == .audio)
        #expect(Signposts.asr.category == .asr)
        #expect(Signposts.voiceID.category == .voiceID)
        #expect(Signposts.realtime.category == .realtime)
        #expect(Signposts.topics.category == .topics)
        #expect(Signposts.memory.category == .memory)
        #expect(Signposts.data.category == .data)
        #expect(Signposts.ui.category == .ui)
    }
}

/// Interval bookkeeping, checked with a recording backend.
@Suite("Signposter, recorded")
struct RecordedSignposterTests {
    let backend = RecordingSignpostBackend()
    var signposter: Signposter { Signposter(category: .asr, backend: backend) }

    @Test func syncIntervalBeginsAndEndsAroundTheBody() {
        let value = signposter.withInterval(.asrChunk) {
            #expect(backend.openIntervals == ["asr.chunk"])
            return 7
        }
        #expect(value == 7)
        #expect(backend.records == [.begin(name: "asr.chunk", id: 1), .end(name: "asr.chunk", id: 1)])
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func intervalEndsWhenTheBodyThrows() {
        #expect(throws: ProbeError()) {
            try signposter.withInterval("asr.chunk") { () throws(ProbeError) in throw ProbeError() }
        }
        #expect(backend.openIntervals.isEmpty)
        #expect(backend.completedIntervals == ["asr.chunk"])
    }

    @Test func asyncIntervalEndsWhenTheBodyThrows() async {
        await #expect(throws: ProbeError()) {
            try await signposter.withInterval(.asrEndOfUtterance) { () async throws(ProbeError) in
                await Task.yield()
                throw ProbeError()
            }
        }
        #expect(backend.openIntervals.isEmpty)
        #expect(backend.completedIntervals == ["asr.eou"])
    }

    @Test func asyncIntervalEndsWhenTheTaskIsCancelled() async {
        let signposter = signposter
        let task = Task {
            try await signposter.withInterval("asr.chunk") {
                try await Task.sleep(for: .seconds(3600))
            }
        }
        while backend.openIntervals.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(backend.openIntervals.isEmpty)
        #expect(backend.completedIntervals == ["asr.chunk"])
    }

    @Test func overlappingIntervalsGetDistinctTokens() async {
        let signposter = signposter
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await signposter.withInterval(.vadChunk) { await Task.yield() }
                }
            }
        }
        let beginIDs = backend.records.compactMap { record -> UInt64? in
            if case .begin(_, let id) = record { id } else { nil }
        }
        let endIDs = backend.records.compactMap { record -> UInt64? in
            if case .end(_, let id) = record { id } else { nil }
        }
        #expect(beginIDs.count == 20)
        #expect(Set(beginIDs).count == 20)
        #expect(Set(endIDs) == Set(beginIDs))
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func nestedIntervalsCloseInsideOut() {
        signposter.withInterval(.realtimeTurn) {
            signposter.withInterval(.realtimeFirstAudio) {}
        }
        #expect(
            backend.records == [
                .begin(name: "realtime.turn", id: 1),
                .begin(name: "realtime.firstAudio", id: 2),
                .end(name: "realtime.firstAudio", id: 2),
                .end(name: "realtime.turn", id: 1),
            ]
        )
    }

    @Test @MainActor func asyncIntervalRunsOnTheCallersActor() async {
        let box = Box()
        let returned = await signposter.withInterval(.topicsLabel) {
            MainActor.assertIsolated()
            await Task.yield()
            box.value += 1
            return box
        }
        #expect(returned === box)
        #expect(box.value == 1)
    }

    @Test func manualIntervalEndsExactlyOnce() async {
        let interval = signposter.beginInterval(.realtimeFirstAudio)
        #expect(backend.openIntervals == ["realtime.firstAudio"])

        let endings = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { interval.end() }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        #expect(endings == 1)
        #expect(interval.isEnded)
        #expect(backend.completedIntervals == ["realtime.firstAudio"])
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func manualIntervalBegunWhileDisabledNeverReachesTheBackend() {
        backend.isEnabled = false
        let interval = signposter.beginInterval("asr.eou")
        backend.isEnabled = true
        #expect(interval.end())
        #expect(backend.records.isEmpty)
    }

    @Test func eventsAreRecorded() {
        signposter.event("realtime.bargeIn")
        signposter.event("realtime.reconnect")
        #expect(backend.events == ["realtime.bargeIn", "realtime.reconnect"])
        #expect(backend.completedIntervals.isEmpty)
    }

    @Test func osBackendIgnoresTokensFromOtherBackends() {
        OSSignpostBackend(category: .asr).endInterval("asr.chunk", SignpostIntervalToken(id: 99))
        OSSignpostBackend.disabled.endInterval("asr.chunk", SignpostIntervalToken(id: 99))
    }
}
