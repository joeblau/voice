import BlauAudio
import Foundation

/// Drives a `StreamingAudioPlayer` the way the audio hardware and the
/// realtime client would, without either: the render thread asks for one
/// I/O cycle at a time, and before each cycle every delta that has
/// "arrived" by then is enqueued. Time is the number of frames rendered so
/// far, at the stream's sample rate.
struct PlaybackSimulation {
    let player: StreamingAudioPlayer
    let fixture: DeltaStreamFixture
    let item: PlaybackItemID

    /// Everything the node rendered.
    private(set) var output: [Float] = []
    private(set) var nextDelta = 0
    private var random: SplitMix64
    /// Frames per render cycle. A 20 ms hardware buffer at 48 kHz asks the
    /// 24 kHz source for ~480 frames, give or take for resampling.
    private let cycleFrames: ClosedRange<Int>

    init(
        player: StreamingAudioPlayer,
        fixture: DeltaStreamFixture,
        item: PlaybackItemID = PlaybackItemID(itemID: "item_fixture"),
        cycleFrames: ClosedRange<Int> = 470...490,
        seed: UInt64 = 7
    ) {
        self.player = player
        self.fixture = fixture
        self.item = item
        self.cycleFrames = cycleFrames
        random = SplitMix64(seed: seed)
    }

    var now: Int { output.count }
    var allDeltasDelivered: Bool { nextDelta == fixture.deltas.count }

    /// Renders cycles until `frame` frames have been rendered, delivering
    /// deltas as they arrive and finishing the item after the last one.
    mutating func run(until frame: Int) throws {
        while now < frame {
            try deliverArrivals()
            renderCycle(count: min(random.next(in: cycleFrames), frame - now))
        }
        try deliverArrivals()
    }

    /// Renders until every delta is delivered and the player is idle again.
    mutating func runToEnd() throws {
        while !allDeltasDelivered || player.snapshot.state != .idle {
            try deliverArrivals()
            renderCycle(count: random.next(in: cycleFrames))
        }
    }

    mutating func renderCycle(count: Int) {
        var cycle = [Float](repeating: .nan, count: count)
        cycle.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
        output += cycle
    }

    private mutating func deliverArrivals() throws {
        while nextDelta < fixture.deltas.count, fixture.deltas[nextDelta].arrivalFrame <= now {
            try player.enqueue(base64: fixture.deltas[nextDelta].base64, item: item)
            nextDelta += 1
            if allDeltasDelivered {
                player.finish(item)
            }
        }
    }

    // MARK: Analysis

    /// Index of the first non-zero output frame: where the item started.
    var firstAudibleFrame: Int? { output.firstIndex { $0 != 0 } }

    /// Where the fixture's first sample sits in the output, assuming no
    /// silence was inserted before its first non-zero sample.
    var alignedStart: Int? {
        guard let output = firstAudibleFrame, let input = fixture.floats.firstIndex(where: { $0 != 0 }) else {
            return nil
        }
        return output - input
    }

    /// Output frames that carry fixture audio. The fixture has no zero
    /// samples, so every non-zero output frame is audio and every zero is
    /// inserted silence.
    var audibleFrameCount: Int { output.count { $0 != 0 } }
}
