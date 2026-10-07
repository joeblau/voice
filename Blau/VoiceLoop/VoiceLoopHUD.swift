import BlauRealtime
import SwiftUI

/// The voice loop's rows of the debug performance HUD: turn state,
/// connection, end of utterance → first audio (last / p50 / p95), turn time
/// and tokens. Shown over the main screen while the `perfHUD` flag is on.
/// The full, draggable HUD with the other subsystems is #71.
struct VoiceLoopHUD: View {
    nonisolated static let accessibilityIdentifier = "blau.hud.voiceLoop"

    let readout: TurnHUDReadout

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(readout.rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

/// Puts the `VoiceLoopHUD` over the content while the `perfHUD` flag is on.
struct VoiceLoopHUDOverlay: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if environment.flags.isEnabled(.perfHUD) {
                VoiceLoopHUD(readout: environment.voiceLoop.hudReadout)
                    .padding(.horizontal)
            }
        }
    }
}

extension View {
    /// Overlays the voice loop HUD when the `perfHUD` flag is on.
    func voiceLoopHUD() -> some View {
        modifier(VoiceLoopHUDOverlay())
    }
}

#Preview("Voice loop HUD") {
    var latency = TurnLatencyStatistics()
    for milliseconds in [610, 640, 700, 980] {
        latency.recordFirstAudio(.milliseconds(milliseconds))
    }
    latency.recordTurn(.milliseconds(3_200))
    var usage = RealtimeUsageTotals()
    usage.add(.init(inputTokens: 412, outputTokens: 96, totalTokens: 508))
    return VoiceLoopHUD(
        readout: TurnHUDReadout(
            TurnSnapshot(state: .agentSpeaking, connection: .connected, latency: latency, usage: usage)))
}
