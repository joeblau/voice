import BlauTelemetry
import Synchronization
import Testing

/// A backend that doesn't implement `endInterval(_:_:message:)`, to check the
/// protocol's default.
private final class MinimalBackend: SignpostBackend {
    let ended = Mutex<[String]>([])
    var isEnabled: Bool { true }
    func beginInterval(_ name: StaticString) -> SignpostIntervalToken { SignpostIntervalToken(id: 1) }
    func endInterval(_ name: StaticString, _ token: SignpostIntervalToken) {
        ended.withLock { $0.append(name.description) }
    }
    func emitEvent(_ name: StaticString) {}
}

@Suite("Signpost end messages")
struct SignpostEndMessageTests {
    @Test func recordsTheEndMessage() {
        let backend = RecordingSignpostBackend()
        let signposter = Signposter(category: .realtime, backend: backend)

        let first = signposter.beginInterval(.realtimeEvent)
        let second = signposter.beginInterval(.realtimeEvent)
        #expect(second.end(message: "response.done"))
        #expect(first.end(message: "session.created"))

        #expect(backend.completedIntervals == ["realtime.event", "realtime.event"])
        #expect(backend.endMessages(of: "realtime.event") == ["response.done", "session.created"])
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func endsOnlyOnce() {
        let backend = RecordingSignpostBackend()
        let interval = Signposter(category: .realtime, backend: backend).beginInterval(.realtimeConnect)

        #expect(interval.end(message: "connected"))
        #expect(!interval.end(message: "again"))
        #expect(!interval.end())

        #expect(backend.endMessages(of: "realtime.connect") == ["connected"])
        #expect(backend.completedIntervals.count == 1)
    }

    @Test func plainEndsHaveNoMessage() {
        let backend = RecordingSignpostBackend()
        let signposter = Signposter(category: .realtime, backend: backend)
        signposter.beginInterval(.realtimeConnect).end()
        signposter.beginInterval(.realtimeConnect).end(message: "failed")

        #expect(backend.endMessages(of: "realtime.connect") == ["failed"])
    }

    @Test func disabledSignpostingNeverBuildsTheMessage() {
        let built = Mutex(false)
        let interval = Signposter.disabled(.realtime).beginInterval(.realtimeEvent)
        let ended = interval.end(
            message: {
                built.withLock { $0 = true }
                return "x"
            }())
        #expect(ended)
        #expect(interval.isEnded)
        #expect(!built.withLock { $0 })
    }

    @Test func backendsWithoutMessagesFallBackToAPlainEnd() {
        let backend = MinimalBackend()
        Signposter(category: .realtime, backend: backend).beginInterval(.realtimeEvent).end(message: "ignored")
        #expect(backend.ended.withLock { $0 } == ["realtime.event"])
    }

    @Test func osBackendAcceptsEndMessages() {
        let interval = Signposter(category: .realtime).beginInterval(.realtimeEvent)
        #expect(interval.end(message: "response.output_audio.delta"))
    }
}
