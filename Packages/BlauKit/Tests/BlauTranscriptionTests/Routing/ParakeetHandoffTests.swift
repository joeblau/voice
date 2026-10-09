import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// #31: the HUD's reference to the Parakeet transcriber must not keep its
/// model in memory once `TranscriberRouter` has switched to Apple's engine
/// (critical memory pressure, `systemSpeech` off screen, the toggle).
@Suite("ParakeetHandoff: the HUD's Parakeet doesn't outlive the router's")
struct ParakeetHandoffTests {
    @Test func theTranscriberBuiltLastIsHeldWeakly() async throws {
        let handoff = ParakeetHandoff()
        let recognizer = SimulatedEouRecognizer(words: [])
        weak var weakTranscriber: ParakeetStreamingTranscriber?
        do {
            let transcriber = makeParakeet(recognizer)
            weakTranscriber = transcriber
            handoff.built(transcriber)
            #expect(handoff.latest === transcriber)
        }
        #expect(weakTranscriber == nil)
        #expect(handoff.latest == nil)
    }

    @Test func aPreloadedTranscriberIsKeptUntilTakenOrReleased() async throws {
        let handoff = ParakeetHandoff()
        let recognizer = SimulatedEouRecognizer(words: [])
        weak var weakTranscriber: ParakeetStreamingTranscriber?
        do {
            let transcriber = makeParakeet(recognizer)
            weakTranscriber = transcriber
            handoff.built(transcriber)
            handoff.preload(transcriber)
        }
        // Nothing else holds it yet: the preload keeps it for the router.
        #expect(weakTranscriber != nil)
        #expect(handoff.latest != nil)

        await handoff.releasePreloaded()
        #expect(await recognizer.unloads == 1)
        #expect(weakTranscriber == nil)
        #expect(handoff.latest == nil)
        #expect(handoff.takePreloaded() == nil)
    }

    @Test func switchingToAppleUnderMemoryPressureFreesParakeet() async throws {
        let handoff = ParakeetHandoff()
        let parakeets = BuiltParakeets()
        let engines = FakeEngines()
        let router = TranscriberRouter(
            parakeet: .init(
                isAvailable: { true },
                make: {
                    let recognizer = SimulatedEouRecognizer(words: [])
                    let transcriber = makeParakeet(recognizer)
                    parakeets.record(transcriber, recognizer: recognizer)
                    handoff.built(transcriber)
                    return transcriber
                }),
            apple: engines.provider(.apple), clock: ManualClock(), signposter: .disabled(.asr))

        try await router.start()
        #expect(router.activeEngine == .parakeet)
        // While Parakeet runs, the HUD reads its counters.
        #expect(handoff.latest != nil)
        #expect(handoff.latest === parakeets.transcriber(0))

        await router.setMemoryPressure(true)
        try await waitUntil { router.status.engine == .apple && router.status.pendingEngine == nil }
        await router.waitForSwitch()

        // The router finished Parakeet: its model is released and nothing,
        // the HUD's handoff included, keeps the transcriber alive.
        #expect(await parakeets.recognizer(0).unloads == 1)
        #expect(await parakeets.recognizer(0).callsAfterUnload == 0)
        try await waitUntil { parakeets.transcriber(0) == nil }
        #expect(handoff.latest == nil)

        // Back to Parakeet once the pressure is over: a new transcriber,
        // which the HUD follows.
        await router.setMemoryPressure(false)
        try await waitUntil { router.status.engine == .parakeet && router.status.pendingEngine == nil }
        await router.waitForSwitch()
        #expect(parakeets.count == 2)
        #expect(handoff.latest != nil)
        #expect(handoff.latest === parakeets.transcriber(1))

        await router.finish()
        #expect(await parakeets.recognizer(1).unloads == 1)
        try await waitUntil { parakeets.transcriber(1) == nil }
        #expect(handoff.latest == nil)
    }
}

/// A Parakeet transcriber on the simulated recognizer (no model), owning
/// it as `ParakeetStreamingTranscriber.load` does.
private func makeParakeet(_ recognizer: SimulatedEouRecognizer) -> ParakeetStreamingTranscriber {
    ParakeetStreamingTranscriber(
        recognizer: recognizer, audio: FixtureAudioSource(block: [Float](repeating: 0, count: 1_600)),
        voiceActivity: ScriptedVoiceActivity(), signposter: .disabled(.asr), clock: ManualClock(),
        latencyMarks: nil, unloadsRecognizerOnFinish: true)
}

/// The Parakeet transcribers a provider built, held weakly, and their
/// recognizers, held strongly so their `unload()` calls can be read.
private final class BuiltParakeets: Sendable {
    private struct Built {
        weak var transcriber: ParakeetStreamingTranscriber?
        let recognizer: SimulatedEouRecognizer
    }

    private let state = Mutex<[Built]>([])

    func record(_ transcriber: ParakeetStreamingTranscriber, recognizer: SimulatedEouRecognizer) {
        state.withLock { $0.append(Built(transcriber: transcriber, recognizer: recognizer)) }
    }

    var count: Int { state.withLock { $0.count } }

    /// The `index`th transcriber built, while it is still alive.
    func transcriber(_ index: Int) -> ParakeetStreamingTranscriber? {
        state.withLock { $0[index].transcriber }
    }

    func recognizer(_ index: Int) -> SimulatedEouRecognizer {
        state.withLock { $0[index].recognizer }
    }
}
