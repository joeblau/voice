import BlauTelemetry
import Foundation

/// The voice loop's lines in the debug performance HUD: turn state,
/// connection, the session's continuity (#39), end of utterance → first
/// audio (last / p50 / p95) and token usage. The app's HUD overlay renders the rows as they are; the full HUD
/// (#71) adds the other subsystems' rows next to them.
public struct TurnHUDReadout: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }

        public var id: String { label }
    }

    public var rows: [Row]

    public init(_ snapshot: TurnSnapshot) {
        var state = snapshot.state.name
        if snapshot.queuedUtterances > 0 {
            state += " (\(snapshot.queuedUtterances) queued)"
        }
        rows = [
            Row(label: "Turn", value: state),
            Row(label: "Realtime", value: Self.describe(snapshot.connection)),
            Row(label: "Session", value: Self.describe(snapshot.session)),
            Row(label: "EOU → audio", value: Self.describe(snapshot.latency.firstAudio)),
            Row(label: "Turn time", value: Self.describe(snapshot.latency.turn)),
            Row(
                label: "Tokens",
                value:
                    "\(snapshot.usage.inputTokens) in · \(snapshot.usage.outputTokens) out · \(snapshot.usage.responses) resp"
            ),
            Row(label: "Barge-in", value: Self.describe(bargeIns: snapshot.bargeIns, last: snapshot.lastBargeIn)),
        ]
    }

    /// The row `label`'s value.
    public func value(for label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    /// `last 640 · p50 610 · p95 900 ms (n=12)`, or `–` before the first
    /// sample.
    static func describe(_ latency: RollingLatency) -> String {
        guard let last = latency.last, let p50 = latency.p50, let p95 = latency.p95 else { return "–" }
        return
            "last \(milliseconds(last)) · p50 \(milliseconds(p50)) · p95 \(milliseconds(p95)) ms (n=\(latency.samples.count))"
    }

    /// `2 · last 0.4 ms to flush (VAD +290 ms)`, or `–` before the first:
    /// how many barge-ins, the onset reaching the monitor → playback
    /// flushed, and VAD's confirmation delay before that.
    static func describe(bargeIns: Int, last: BargeInRecord?) -> String {
        guard bargeIns > 0, let last else { return "–" }
        let reaction = String(format: "%.1f", last.reactionTime.milliseconds)
        return "\(bargeIns) · last \(reaction) ms to flush (VAD +\(milliseconds(last.detectionLatency)) ms)"
    }

    static func describe(_ connection: RealtimeClient.ConnectionState) -> String {
        switch connection {
        case .connected: "connected"
        case .connecting(let attempt): "connecting (\(attempt))"
        case .reconnecting(let attempt): "reconnecting (\(attempt))"
        case .disconnected(nil): "disconnected"
        case .disconnected(let error?): "disconnected: \(error.description)"
        }
    }

    /// `live · 42 min · 1 renewed · 2 resumed · 1 reseeded`; the counts
    /// only once they are non-zero.
    static func describe(_ session: RealtimeSessionContinuity) -> String {
        var parts = [session.phase.rawValue]
        if session.phase != .idle {
            parts.append("\(session.sessionAge.components.seconds / 60) min")
        }
        if session.rollovers > 0 { parts.append("\(session.rollovers) renewed") }
        if session.resumptions > 0 { parts.append("\(session.resumptions) resumed") }
        if session.reseeds > 0 { parts.append("\(session.reseeds) reseeded") }
        return parts.joined(separator: " · ")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        "\(Int(duration.milliseconds.rounded()))"
    }
}
