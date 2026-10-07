import Synchronization
import Testing

@testable import BlauAudio

/// Stands in for `AVAudioInputNode`: records the mute and keeps the
/// listener so a test can play the voice-processing unit's role.
private final class FakeVoiceInput: VoiceProcessingInputMuting {
    private struct State {
        var isMuted = false
        var listener: (@Sendable (MutedSpeechActivity) -> Void)?
        var listenerChanges = 0
    }

    private let state = Mutex(State())

    var isVoiceProcessingInputMuted: Bool {
        get { state.withLock { $0.isMuted } }
        set { state.withLock { $0.isMuted = newValue } }
    }

    var hasListener: Bool { state.withLock { $0.listener != nil } }

    @discardableResult
    func setMutedSpeechActivityListener(_ listener: (@Sendable (MutedSpeechActivity) -> Void)?) -> Bool {
        state.withLock {
            $0.listener = listener
            $0.listenerChanges += 1
        }
        return true
    }

    /// What the voice-processing unit does when it hears speech.
    func detect(_ activity: MutedSpeechActivity) {
        let listener = state.withLock { $0.listener }
        listener?(activity)
    }
}

/// Collects a stream's elements on a task of its own.
private final class Collector<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<Element>) {
        let collecting = Task { [self] in
            for await item in stream {
                items.withLock { $0.append(item) }
            }
        }
        task.withLock { $0 = collecting }
    }

    var values: [Element] { items.withLock { $0 } }

    func cancel() {
        task.withLock { $0?.cancel() }
    }
}

private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() {
        await Task.yield()
        try? await Task.sleep(for: .microseconds(200))
    }
}

@Suite("MicrophoneMute", .timeLimit(.minutes(1)))
struct MicrophoneMuteTests {
    @Test func startsUnmutedAndAppliesTheMuteToTheAttachedInput() {
        let mute = MicrophoneMute()
        let input = FakeVoiceInput()
        mute.attach(to: input)
        #expect(!mute.isMuted)
        #expect(!input.isVoiceProcessingInputMuted)
        #expect(input.hasListener)

        mute.setMuted(true)
        #expect(mute.isMuted)
        #expect(input.isVoiceProcessingInputMuted)

        mute.setMuted(false)
        #expect(!input.isVoiceProcessingInputMuted)
    }

    /// The graph is rebuilt on every route change and interruption; a new
    /// input node must come up muted when the user paused listening.
    @Test func theMuteSurvivesAGraphRebuild() {
        let mute = MicrophoneMute()
        let first = FakeVoiceInput()
        mute.attach(to: first)
        mute.setMuted(true)

        mute.detach()
        #expect(!first.isVoiceProcessingInputMuted, "a detached node is left unmuted")
        #expect(!first.hasListener)
        #expect(mute.isMuted)

        let second = FakeVoiceInput()
        mute.attach(to: second)
        #expect(second.isVoiceProcessingInputMuted)
        #expect(second.hasListener)
    }

    @Test func mutingBeforeTheGraphExistsAppliesOnInstall() {
        let mute = MicrophoneMute()
        mute.setMuted(true)
        let input = FakeVoiceInput()
        mute.attach(to: input)
        #expect(input.isVoiceProcessingInputMuted)
    }

    @Test func reportsSpeechOnlyWhileMuted() async {
        let mute = MicrophoneMute()
        let input = FakeVoiceInput()
        mute.attach(to: input)
        let collector = Collector(mute.speechActivity())
        defer { collector.cancel() }

        input.detect(.started)  // unmuted: ignored
        input.detect(.ended)
        mute.setMuted(true)
        input.detect(.started)
        input.detect(.started)  // repeated: ignored
        input.detect(.ended)

        await waitFor { collector.values.count >= 2 }
        #expect(collector.values == [.started, .ended])
    }

    @Test func unmutingEndsSpeechInProgress() async {
        let mute = MicrophoneMute()
        let input = FakeVoiceInput()
        mute.attach(to: input)
        let collector = Collector(mute.speechActivity())
        defer { collector.cancel() }

        mute.setMuted(true)
        input.detect(.started)
        mute.setMuted(false)

        await waitFor { collector.values.count >= 2 }
        #expect(collector.values == [.started, .ended])
    }

    @Test func everySubscriberHearsIt() async {
        let mute = MicrophoneMute()
        let input = FakeVoiceInput()
        mute.attach(to: input)
        let first = Collector(mute.speechActivity())
        let second = Collector(mute.speechActivity())
        defer {
            first.cancel()
            second.cancel()
        }

        mute.setMuted(true)
        input.detect(.started)

        await waitFor { first.values.count == 1 && second.values.count == 1 }
        #expect(first.values == [.started])
        #expect(second.values == [.started])
    }
}

@Suite("LevelMeter")
struct LevelMeterTests {
    @Test func risesFastAndFallsSlowly() {
        var meter = LevelMeter(attack: .milliseconds(40), release: .milliseconds(250))
        let risen = meter.update(to: 1, elapsed: .milliseconds(40))
        // One time constant covers 1 - 1/e of the distance.
        #expect(abs(risen - 0.632) < 0.01)

        meter.update(to: 1, elapsed: .milliseconds(400))
        #expect(meter.value == 1)

        let fallen = meter.update(to: 0, elapsed: .milliseconds(40))
        #expect(fallen > 0.8, "a 40 ms release step only drops ~15%")
    }

    @Test func doesNotDependOnTheUpdateRate() {
        var coarse = LevelMeter()
        var fine = LevelMeter()
        coarse.update(to: 0.8, elapsed: .milliseconds(60))
        for _ in 0..<3 {
            fine.update(to: 0.8, elapsed: .milliseconds(20))
        }
        #expect(abs(coarse.value - fine.value) < 0.001)
    }

    @Test func clampsAndSnapsToSilence() {
        var meter = LevelMeter()
        #expect(meter.update(to: 3, elapsed: .seconds(1)) == 1)
        #expect(meter.update(to: -.infinity, elapsed: .seconds(5)) == 0)
        #expect(meter.update(to: .nan, elapsed: .seconds(1)) == 0)
        meter.update(to: 0.5, elapsed: .zero)
        #expect(meter.value == 0, "no time, no movement")
    }

    @Test func resetDropsToZero() {
        var meter = LevelMeter()
        meter.update(to: 1, elapsed: .seconds(1))
        meter.reset()
        #expect(meter.value == 0)
    }

    @Test func playbackLevelsUseTheSameScaleAsInputLevels() {
        let amplitude: Float = 0.1  // -20 dBFS
        let input = AudioLevel(rms: amplitude, peak: amplitude, sampleOffset: 0).normalized(floor: -60)
        let output = PlaybackLevel(rms: amplitude, peak: amplitude).normalized(floor: -60)
        #expect(abs(input - output) < 0.0001)
        #expect(abs(output - 2.0 / 3.0) < 0.001)
        #expect(PlaybackLevel.silent.normalized() == 0)
        #expect(PlaybackLevel(rms: 1, peak: 1).normalized() == 1)
    }
}
