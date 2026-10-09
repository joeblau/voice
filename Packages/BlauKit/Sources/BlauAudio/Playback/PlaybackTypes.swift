import BlauCore
import Foundation

/// Identifies the audio of one response item, as the realtime API names it:
/// `response.output_audio.delta` carries `item_id` and `content_index`, and
/// `conversation.item.truncate` takes the same pair plus `audio_end_ms`.
public struct PlaybackItemID: Sendable, Hashable, CustomStringConvertible {
    /// The conversation item's ID (`item_id`).
    public var itemID: String
    /// The content part within the item (`content_index`).
    public var contentIndex: Int

    public init(itemID: String, contentIndex: Int = 0) {
        self.itemID = itemID
        self.contentIndex = contentIndex
    }

    public var description: String { "\(itemID)#\(contentIndex)" }
}

/// What the player is doing.
public enum PlaybackState: String, Sendable, Hashable {
    /// Nothing queued; the node renders silence.
    case idle
    /// Audio is queued but the jitter buffer hasn't filled yet (at the start
    /// of a response, or after an underrun). The node renders silence.
    case buffering
    /// Rendering queued audio.
    case playing
}

/// The output level of the most recent render cycle, linear in `0...1`.
public struct PlaybackLevel: Sendable, Hashable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silent = PlaybackLevel(rms: 0, peak: 0)

    /// RMS level in dBFS, floored at `floor`. Handy for a level meter.
    public func decibels(floor: Float = -80) -> Float {
        guard rms > 0 else { return floor }
        return max(floor, 20 * log10(rms))
    }
}

/// How much of one response item has been played.
public struct PlayedItem: Sendable, Hashable {
    public var id: PlaybackItemID
    /// Frames rendered to the output, at the stream's sample rate.
    public var playedFrames: Int64
    /// Frames received for the item.
    public var receivedFrames: Int64
    /// The stream's sample rate.
    public var sampleRate: Int
    /// When the item's first frame was rendered for the output, on the
    /// player's clock (`BlauClock.uptime`); `nil` until it has been. The end
    /// of the latency budget's "first buffer" hop (#74).
    public var firstRenderedAt: Duration?

    public init(
        id: PlaybackItemID, playedFrames: Int64, receivedFrames: Int64, sampleRate: Int,
        firstRenderedAt: Duration? = nil
    ) {
        self.id = id
        self.playedFrames = playedFrames
        self.receivedFrames = receivedFrames
        self.sampleRate = sampleRate
        self.firstRenderedAt = firstRenderedAt
    }

    /// The audio the user heard from this item.
    public var playedDuration: Duration { .samples(playedFrames, sampleRate: sampleRate) }

    /// `audio_end_ms` for `conversation.item.truncate`: whole milliseconds
    /// played, rounded down so the transcript is never cut after what was
    /// heard.
    public var playedMilliseconds: Int { Int(playedFrames * 1000 / Int64(sampleRate)) }
}

/// What `flush()` interrupted.
public struct PlaybackFlushResult: Sendable, Hashable {
    /// Every item that still had unplayed audio queued (or was still
    /// streaming), in queue order, with how much of it was played. The
    /// first one is what the user was hearing; send
    /// `conversation.item.truncate` with its `playedMilliseconds`.
    public var interrupted: [PlayedItem]
    /// Audio dropped from the queue.
    public var droppedDuration: Duration

    public init(interrupted: [PlayedItem], droppedDuration: Duration) {
        self.interrupted = interrupted
        self.droppedDuration = droppedDuration
    }

    /// The item the user was hearing (or about to hear) when flushed.
    public var current: PlayedItem? { interrupted.first }
}

/// A point-in-time view of the player, for the "agent speaking" indicator
/// and diagnostics.
public struct PlaybackSnapshot: Sendable, Hashable {
    public var state: PlaybackState
    /// The level of the last render cycle.
    public var level: PlaybackLevel
    /// Audio queued and not yet played.
    public var bufferedDuration: Duration
    /// The item now playing, or next to play.
    public var currentItem: PlaybackItemID?
    /// How often the queue ran dry while more audio was expected.
    public var underrunCount: Int
    /// Total frames rendered by the node (silence included), at the stream's
    /// sample rate.
    public var renderedFrames: Int64
    /// Frames of audio played since the player last left `idle`, across
    /// items: how long the agent's voice has been coming out without a
    /// break. Back to 0 when the player goes idle (the queue drained or a
    /// flush); an underrun keeps it.
    public var playedSinceIdleFrames: Int64

    public init(
        state: PlaybackState,
        level: PlaybackLevel,
        bufferedDuration: Duration,
        currentItem: PlaybackItemID?,
        underrunCount: Int,
        renderedFrames: Int64,
        playedSinceIdleFrames: Int64 = 0
    ) {
        self.state = state
        self.level = level
        self.bufferedDuration = bufferedDuration
        self.currentItem = currentItem
        self.underrunCount = underrunCount
        self.renderedFrames = renderedFrames
        self.playedSinceIdleFrames = playedSinceIdleFrames
    }

    /// Whether the agent is audibly speaking.
    public var isSpeaking: Bool { state == .playing }
}

/// Why audio couldn't be enqueued.
public enum PlaybackError: Error, Sendable, Hashable {
    /// The delta wasn't valid base64.
    case invalidBase64
}

/// What happened to an enqueued delta.
public enum EnqueueResult: Sendable, Hashable {
    /// Queued for playback.
    case queued
    /// Dropped: the item was flushed by a barge-in (deltas still in flight
    /// when `response.cancel` was sent) or already finished.
    case droppedStaleItem
    /// Nothing to play (an empty delta, or a single byte held back until
    /// its sample's second byte arrives).
    case empty
}
