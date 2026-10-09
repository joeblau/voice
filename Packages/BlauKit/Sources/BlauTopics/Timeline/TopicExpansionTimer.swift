import BlauCore
import BlauTelemetry
import Foundation
import Observation
import os

/// Measures how long a tapped bullet on the timeline takes to expand (#58,
/// target under 100 ms): from the tap to the moment its detail (summary,
/// duration, actions) is laid out under it.
///
/// The view calls ``began(_:)`` when a tap expands a topic and
/// ``appeared(_:)`` from the detail's `onAppear`, which SwiftUI calls in the
/// same transaction as the frame that first shows it. Each measurement is a
/// `timeline.expand` signpost interval (docs/performance.md), a log line,
/// and a sample kept here: the latest (``last``, which the UI tests read)
/// and the slowest of the recent ones (``slowest``).
///
/// A topic compressed again before its detail appeared ends its interval
/// with the message "compressed" and records no sample.
@MainActor
@Observable
public final class TopicExpansionTimer {
    /// One expansion.
    public struct Sample: Sendable, Hashable {
        public var topicID: UUID
        public var latency: Duration

        public init(topicID: UUID, latency: Duration) {
            self.topicID = topicID
            self.latency = latency
        }
    }

    /// The latest expansion.
    public private(set) var last: Sample?
    /// The recent expansions, oldest first, at most ``capacity``.
    public private(set) var recent: [Duration] = []

    public let capacity: Int
    /// The target the issue sets: under 100 ms.
    public static let target: Duration = .milliseconds(100)

    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private let signposter: Signposter
    @ObservationIgnored private var pending: [UUID: (interval: SignpostInterval, startedAt: Duration)] = [:]

    public init(clock: any BlauClock = SystemClock(), signposter: Signposter = Signposts.ui, capacity: Int = 50) {
        precondition(capacity > 0, "A timer keeps at least one sample")
        self.clock = clock
        self.signposter = signposter
        self.capacity = capacity
    }

    isolated deinit {
        for entry in pending.values {
            entry.interval.end(message: "cancelled")
        }
    }

    /// The slowest of the ``recent`` expansions.
    public var slowest: Duration? { recent.max() }

    /// Whether an expansion of `topicID` is being measured.
    public func isMeasuring(_ topicID: UUID) -> Bool { pending[topicID] != nil }

    /// A tap expanded `topicID`: the measurement starts. A second tap
    /// before the first one's detail appeared restarts it.
    public func began(_ topicID: UUID) {
        pending.removeValue(forKey: topicID)?.interval.end(message: "superseded")
        pending[topicID] = (signposter.beginInterval(.timelineExpand), clock.uptime)
    }

    /// `topicID` was compressed (or went away) before its detail appeared.
    public func cancelled(_ topicID: UUID) {
        pending.removeValue(forKey: topicID)?.interval.end(message: "compressed")
    }

    /// Stops measuring topics that are gone (merged or deleted).
    public func retain(only ids: Set<UUID>) {
        for id in pending.keys where !ids.contains(id) {
            pending.removeValue(forKey: id)?.interval.end(message: "removed")
        }
    }

    /// `topicID`'s detail appeared.
    ///
    /// - Returns: How long it took since the tap, or `nil` when no tap is
    ///   being measured for it (a topic that was already expanded and
    ///   scrolled back into view).
    @discardableResult
    public func appeared(_ topicID: UUID) -> Duration? {
        guard let entry = pending.removeValue(forKey: topicID) else { return nil }
        let latency = clock.uptime - entry.startedAt
        entry.interval.end(message: "expanded")
        last = Sample(topicID: topicID, latency: latency)
        recent.append(latency)
        if recent.count > capacity {
            recent.removeFirst(recent.count - capacity)
        }
        let milliseconds = latency / .milliseconds(1)
        if latency > Self.target {
            Log.ui.notice(
                "Topic expanded in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms, over the 100 ms target"
            )
        } else {
            Log.ui.debug("Topic expanded in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        }
        return latency
    }
}
