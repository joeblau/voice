import BlauTelemetry
import Foundation
import Synchronization
import Testing

/// Records what `MetricKitSignpostBackend` would send to `mxSignpost`.
final class RecordingMetricEmitter: MetricSignpostEmitter {
    enum Call: Hashable {
        case begin(String, UInt64)
        case end(String, UInt64)
    }

    private let state: Mutex<(enabled: Bool, calls: [Call])>

    init(isEnabled: Bool = true) {
        state = Mutex((isEnabled, []))
    }

    var isEnabled: Bool { state.withLock { $0.enabled } }
    var calls: [Call] { state.withLock { $0.calls } }

    func beginInterval(_ name: StaticString, id: UInt64) {
        state.withLock { $0.calls.append(.begin(name.description, id)) }
    }

    func endInterval(_ name: StaticString, id: UInt64) {
        state.withLock { $0.calls.append(.end(name.description, id)) }
    }
}

@Suite("MetricKit signposts")
struct MetricKitSignpostTests {
    let base = RecordingSignpostBackend()
    let emitter = RecordingMetricEmitter()

    func makeSignposter(category: LogCategory = .realtime) -> Signposter {
        let backend = MetricKitSignpostBackend(
            base: base, emitter: emitter,
            reportedIntervals: PipelineInterval.metricKitIntervals(in: category).map(\.name))
        return Signposter(category: category, backend: backend)
    }

    @Test func reportedIntervalsGoToBothBackends() {
        let signposter = makeSignposter()
        signposter.withInterval(.realtimeTurn) {}

        #expect(base.completedIntervals == ["realtime.turn"])
        #expect(emitter.calls == [.begin("realtime.turn", 1), .end("realtime.turn", 1)])
    }

    @Test func otherIntervalsStayInstrumentsOnly() {
        let signposter = makeSignposter(category: .asr)
        signposter.withInterval(.asrChunk) {}
        signposter.withInterval(.asrEndOfUtterance) {}

        #expect(base.completedIntervals == ["asr.chunk", "asr.eou"])
        #expect(emitter.calls == [.begin("asr.eou", 1), .end("asr.eou", 1)])
    }

    @Test func adHocLiteralWithACanonicalNameIsReported() {
        let signposter = makeSignposter()
        signposter.withInterval("realtime.firstAudio") {}
        signposter.withInterval("realtime.debugThing") {}
        #expect(emitter.calls == [.begin("realtime.firstAudio", 1), .end("realtime.firstAudio", 1)])
    }

    @Test func overlappingIntervalsGetTheirOwnMetricKitIDs() {
        let signposter = makeSignposter()
        let first = signposter.beginInterval(.realtimeFirstAudio)
        let second = signposter.beginInterval(.realtimeFirstAudio)
        second.end()
        first.end()
        first.end()  // ending twice does nothing

        #expect(
            emitter.calls == [
                .begin("realtime.firstAudio", 1), .begin("realtime.firstAudio", 2),
                .end("realtime.firstAudio", 2), .end("realtime.firstAudio", 1),
            ])
        #expect(base.openIntervals.isEmpty)
    }

    @Test func endsWhenTheBodyThrows() {
        struct Failure: Error {}
        let signposter = makeSignposter()
        #expect(throws: Failure.self) { try signposter.withInterval(.realtimeTurn) { throw Failure() } }
        #expect(emitter.calls.count == 2)
        #expect(base.openIntervals.isEmpty)
    }

    /// `realtime.event` and `realtime.connect` end with a message (#104); the
    /// realtime signposter is a `MetricKitSignpostBackend`, so it must pass
    /// the message on rather than fall back to the default that drops it.
    @Test func endMessagesReachTheBase() {
        let signposter = makeSignposter()
        signposter.beginInterval(.realtimeEvent).end(message: "response.output_audio.delta")
        signposter.beginInterval(.realtimeTurn).end(message: "completed")

        #expect(base.endMessages(of: "realtime.event") == ["response.output_audio.delta"])
        #expect(base.endMessages(of: "realtime.turn") == ["completed"])
        #expect(emitter.calls == [.begin("realtime.turn", 1), .end("realtime.turn", 1)])
    }

    @Test func eventsOnlyGoToTheBase() {
        makeSignposter().event("realtime.bargeIn")
        #expect(base.events == ["realtime.bargeIn"])
        #expect(emitter.calls.isEmpty)
    }

    @Test func disabledEmitterSkipsMetricKit() {
        let disabled = RecordingMetricEmitter(isEnabled: false)
        let backend = MetricKitSignpostBackend(
            base: base, emitter: disabled, reportedIntervals: [PipelineInterval.realtimeTurn.name])
        Signposter(category: .realtime, backend: backend).withInterval(.realtimeTurn) {}
        #expect(base.completedIntervals == ["realtime.turn"])
        #expect(disabled.calls.isEmpty)
    }

    @Test func disabledBaseStillReportsToMetricKit() {
        let disabledBase = RecordingSignpostBackend(isEnabled: false)
        let backend = MetricKitSignpostBackend(
            base: disabledBase, emitter: emitter, reportedIntervals: [PipelineInterval.realtimeTurn.name])
        #expect(backend.isEnabled)

        let signposter = Signposter(category: .realtime, backend: backend)
        signposter.withInterval(.realtimeTurn) {}
        signposter.event("realtime.bargeIn")

        #expect(disabledBase.records.isEmpty, "a disabled base is never called")
        #expect(emitter.calls == [.begin("realtime.turn", 1), .end("realtime.turn", 1)])
    }

    @Test func bothDisabledMeansDisabled() {
        let backend = MetricKitSignpostBackend(
            base: RecordingSignpostBackend(isEnabled: false), emitter: RecordingMetricEmitter(isEnabled: false),
            reportedIntervals: [PipelineInterval.realtimeTurn.name])
        #expect(!backend.isEnabled)
    }

    // MARK: Which intervals

    @Test func reportsOnlyLowFrequencyUserFacingIntervals() {
        #expect(
            PipelineInterval.allCases.filter(\.reportsToMetricKit).map(\.name.description) == [
                "asr.eou", "voiceid.verify", "voiceid.gate", "realtime.turn", "realtime.firstAudio", "topics.label",
                "memory.search",
            ])
    }

    @Test func intervalsByCategory() {
        #expect(PipelineInterval.metricKitIntervals(in: .realtime) == [.realtimeTurn, .realtimeFirstAudio])
        #expect(PipelineInterval.metricKitIntervals(in: .audio).isEmpty)
        #expect(!PipelineInterval.playbackFirstBuffer.reportsToMetricKit)
        #expect(!PipelineInterval.realtimeConnect.reportsToMetricKit)
        #expect(!PipelineInterval.realtimeEvent.reportsToMetricKit)
    }

    @Test func defaultBackendsAddMetricKitWhereNeeded() {
        #if canImport(MetricKit)
            #expect(Signposts.defaultBackend(for: .realtime) is MetricKitSignpostBackend)
            let realtime = (Signposts.realtime.backend as? TappedSignpostBackend)?.base as? MetricKitSignpostBackend
            #expect(realtime?.reportedIntervals.map(\.description) == ["realtime.turn", "realtime.firstAudio"])
        #endif
        #expect(Signposts.defaultBackend(for: .audio) is OSSignpostBackend)
        #expect(Signposts.defaultBackend(for: .data) is OSSignpostBackend)
    }

    /// docs/performance.md's MetricKit table must list exactly the reported
    /// intervals.
    @Test func performanceDocListsTheMetricKitIntervals() throws {
        let doc = try PipelineIntervalTests.performanceDoc()
        var documented: [String] = []
        var inSection = false
        for line in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                inSection = line.hasPrefix("### Intervals reported to MetricKit")
                continue
            }
            guard inSection, line.hasPrefix("| `") else { continue }
            let cell = line.split(separator: "|").first?.trimmingCharacters(in: .whitespaces) ?? ""
            documented.append(cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
        }
        #expect(documented == PipelineInterval.allCases.filter(\.reportsToMetricKit).map(\.name.description))
    }
}
