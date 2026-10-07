#if DEBUG
    import BlauVoiceID
    import SwiftUI

    /// The voice ID gate's calibrated thresholds and where they came from
    /// (#48, docs/voice-id-eval.md). DEBUG builds only.
    struct VoiceIDThresholdsSection: View {
        let config: VoiceIDConfig

        var body: some View {
            Section {
                LabeledContent("Scoring", value: config.scoring.description)
                LabeledContent("Model", value: config.modelIdentifier)
                row("Under 3 s", config.short)
                row("3 s and longer", config.long)
                if let calibration = config.calibration {
                    LabeledContent("Calibrated", value: calibration.date)
                    LabeledContent(
                        "Budgets",
                        value: "FAR ≤ \(percent(calibration.maximumFalseAcceptRate)), "
                            + "FRR ≤ \(percent(calibration.maximumFalseRejectRate))")
                }
            } header: {
                Text("Voice ID thresholds")
            } footer: {
                Text(
                    "Accept at or above T_hi, reject below T_lo, uncertain in between. "
                        + (config.calibration.map { "Calibrated on \($0.dataset)." } ?? ""))
            }
        }

        private func row(_ title: String, _ thresholds: VoiceIDThresholds) -> some View {
            LabeledContent(
                title,
                value: "T_hi \(thresholds.accept.formatted(.number.precision(.fractionLength(2)))) · "
                    + "T_lo \(thresholds.reject.formatted(.number.precision(.fractionLength(2))))")
        }

        private func percent(_ value: Double) -> String {
            value.formatted(.percent.precision(.fractionLength(0...1)))
        }
    }

    #Preview("Voice ID thresholds") {
        Form {
            VoiceIDThresholdsSection(config: .calibrated)
        }
    }
#endif
