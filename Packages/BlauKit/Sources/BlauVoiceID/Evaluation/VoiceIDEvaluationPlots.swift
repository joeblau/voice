import Foundation

/// SVG charts of an evaluation report, for docs/voice-id-eval.md: DET curves
/// on probit axes and score histograms with the thresholds.
///
/// Self-contained SVG (no scripts, no external fonts), readable on GitHub in
/// light and dark mode (a white plot area).
public enum VoiceIDEvaluationPlots {
    /// One curve on a DET plot.
    public struct Series: Sendable {
        public let label: String
        public let points: [VoiceIDOperatingPoint]
        public let color: String
        public let dashed: Bool

        public init(label: String, points: [VoiceIDOperatingPoint], color: String, dashed: Bool = false) {
            self.label = label
            self.points = points
            self.color = color
            self.dashed = dashed
        }
    }

    /// A colour-blind-safe palette (Okabe-Ito).
    public static let palette = ["#0072B2", "#D55E00", "#009E73", "#CC79A7", "#E69F00", "#56B4E9", "#000000"]

    /// The DET curves of the calibration method at every window, pooled over
    /// conditions.
    public static func detByWindow(_ report: VoiceIDEvaluationReport) -> String {
        let series = report.windows.enumerated().compactMap { index, window -> Series? in
            report.metrics(scoring: report.calibration.scoring, window: window).map {
                Series(
                    label:
                        "\(VoiceIDEvaluationReport.seconds(window)) (EER \(VoiceIDEvaluationReport.percent($0.equalErrorRate)))",
                    points: $0.curve, color: palette[index % palette.count])
            }
        }
        return det(series, title: "DET by window: \(report.calibration.scoring), all conditions")
    }

    /// The DET curves of every scoring method at the calibration windows
    /// (short dashed, long solid), pooled over conditions.
    public static func detByScoring(_ report: VoiceIDEvaluationReport) -> String {
        let windows = [report.histograms.first?.window, report.histograms.last?.window].compactMap { $0 }
        var series: [Series] = []
        for (index, scoring) in report.scorings.enumerated() {
            for window in windows {
                guard let metrics = report.metrics(scoring: scoring, window: window) else { continue }
                series.append(
                    Series(
                        label:
                            "\(scoring), \(VoiceIDEvaluationReport.seconds(window)) (EER \(VoiceIDEvaluationReport.percent(metrics.equalErrorRate)))",
                        points: metrics.curve, color: palette[index % palette.count],
                        dashed: window == windows.first && windows.count > 1))
            }
        }
        return det(series, title: "DET by scoring method, all conditions")
    }

    /// The DET curves of each condition at `window`, calibration method.
    public static func detByCondition(_ report: VoiceIDEvaluationReport, window: Double) -> String {
        let series = report.conditions.enumerated().compactMap { index, condition -> Series? in
            report.metrics(scoring: report.calibration.scoring, window: window, condition: condition.name).map {
                Series(
                    label: "\(condition.name) (EER \(VoiceIDEvaluationReport.percent($0.equalErrorRate)))",
                    points: $0.curve, color: palette[index % palette.count])
            }
        }
        return det(
            series,
            title: "DET by condition at \(VoiceIDEvaluationReport.seconds(window)): \(report.calibration.scoring)")
    }

    // MARK: DET

    /// A DET plot: false reject against false accept rate, both on probit
    /// (normal deviate) axes from 0.1% to 50%.
    public static func det(_ series: [Series], title: String) -> String {
        let width = 860.0
        let height = 500.0
        let plot = (x: 70.0, y: 40.0, width: 400.0, height: 400.0)
        let ticks = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.4]
        let low = Probit.deviate(0.001)
        let high = Probit.deviate(0.5)
        func x(_ rate: Double) -> Double {
            plot.x + (Probit.deviate(rate) - low) / (high - low) * plot.width
        }
        func y(_ rate: Double) -> Double {
            plot.y + plot.height - (Probit.deviate(rate) - low) / (high - low) * plot.height
        }
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(max(value, lower), upper) }

        var svg = header(width: width, height: height, title: title)
        svg += rect(plot.x, plot.y, plot.width, plot.height, fill: "#ffffff", stroke: "#888888")
        for tick in ticks {
            let tx = x(tick)
            let ty = y(tick)
            svg += line(tx, plot.y, tx, plot.y + plot.height, stroke: "#e5e5e5")
            svg += line(plot.x, ty, plot.x + plot.width, ty, stroke: "#e5e5e5")
            svg += text(tick: tick, x: tx, y: plot.y + plot.height + 16, anchor: "middle")
            svg += text(tick: tick, x: plot.x - 6, y: ty + 4, anchor: "end")
        }
        // The EER diagonal.
        svg += line(x(0.001), y(0.001), x(0.5), y(0.5), stroke: "#bbbbbb", dash: "2 4")
        svg += label(
            "False accept rate (%)", x: plot.x + plot.width / 2, y: plot.y + plot.height + 36, anchor: "middle")
        svg += """
            <text x="18" y="\(fmt(plot.y + plot.height / 2))" font-size="12" text-anchor="middle" \
            transform="rotate(-90 18 \(fmt(plot.y + plot.height / 2)))" fill="#333333">False reject rate (%)</text>

            """
        svg += "<clipPath id=\"plot\"><rect x=\"\(fmt(plot.x))\" y=\"\(fmt(plot.y))\" "
        svg += "width=\"\(fmt(plot.width))\" height=\"\(fmt(plot.height))\"/></clipPath>\n"
        for item in series {
            let coordinates = item.points.map { point in
                "\(fmt(clamp(x(point.falseAcceptRate), plot.x - 5, plot.x + plot.width + 5))),"
                    + "\(fmt(clamp(y(point.falseRejectRate), plot.y - 5, plot.y + plot.height + 5)))"
            }
            let dash = item.dashed ? " stroke-dasharray=\"6 4\"" : ""
            svg +=
                "<polyline clip-path=\"url(#plot)\" fill=\"none\" stroke=\"\(item.color)\" stroke-width=\"2\"\(dash) "
            svg += "points=\"\(coordinates.joined(separator: " "))\"/>\n"
        }
        // Legend, right of the plot.
        for (index, item) in series.enumerated() {
            let ly = plot.y + 10 + Double(index) * 20
            let dash = item.dashed ? "6 4" : nil
            svg += line(
                plot.x + plot.width + 14, ly, plot.x + plot.width + 38, ly, stroke: item.color, width: 2, dash: dash)
            svg += label(item.label, x: plot.x + plot.width + 44, y: ly + 4, anchor: "start", size: 10)
        }
        return svg + "</svg>\n"
    }

    // MARK: Histogram

    /// Target and non-target score histograms (each normalized to its own
    /// total) with `T_lo` and `T_hi` marked.
    public static func histogram(_ histogram: VoiceIDScoreHistogram, title: String) -> String {
        let width = 640.0
        let height = 380.0
        let plot = (x: 60.0, y: 40.0, width: 540.0, height: 260.0)
        let bins = histogram.targetCounts.count
        let targetTotal = max(1, histogram.targetCounts.reduce(0, +))
        let nonTargetTotal = max(1, histogram.nonTargetCounts.reduce(0, +))
        let targetShare = histogram.targetCounts.map { Double($0) / Double(targetTotal) }
        let nonTargetShare = histogram.nonTargetCounts.map { Double($0) / Double(nonTargetTotal) }
        let peak = max(targetShare.max() ?? 0, nonTargetShare.max() ?? 0, 1e-9)
        let low = Double(histogram.lowerBound)
        let high = low + Double(histogram.binWidth) * Double(bins)
        func x(_ score: Double) -> Double { plot.x + (score - low) / (high - low) * plot.width }
        func y(_ share: Double) -> Double { plot.y + plot.height - share / peak * plot.height }

        var svg = header(width: width, height: height, title: title)
        svg += rect(plot.x, plot.y, plot.width, plot.height, fill: "#ffffff", stroke: "#888888")
        let barWidth = plot.width / Double(bins)
        for (shares, color) in [(nonTargetShare, palette[1]), (targetShare, palette[0])] {
            for (index, share) in shares.enumerated() where share > 0 {
                let top = y(share)
                svg += rect(
                    plot.x + Double(index) * barWidth, top, barWidth, plot.y + plot.height - top, fill: color,
                    stroke: nil, opacity: 0.55)
            }
        }
        var tick = (low * 10).rounded(.up) / 10
        while tick <= high + 1e-9 {
            svg += line(x(tick), plot.y + plot.height, x(tick), plot.y + plot.height + 4, stroke: "#888888")
            svg += label(
                String(format: "%.1f", tick), x: x(tick), y: plot.y + plot.height + 16, anchor: "middle", size: 10)
            tick += 0.1
        }
        for (name, value) in [("T_lo", histogram.thresholds.reject), ("T_hi", histogram.thresholds.accept)] {
            let tx = x(Double(value))
            svg += line(tx, plot.y, tx, plot.y + plot.height, stroke: "#333333", width: 1.5, dash: "4 3")
            svg += label("\(name) \(String(format: "%.2f", value))", x: tx, y: plot.y - 6, anchor: "middle", size: 10)
        }
        svg += label("Score", x: plot.x + plot.width / 2, y: plot.y + plot.height + 36, anchor: "middle")
        let legendY = plot.y + plot.height + 50
        svg += rect(plot.x, legendY, 12, 12, fill: palette[0], stroke: nil, opacity: 0.55)
        svg += label("Owner (target) trials", x: plot.x + 18, y: legendY + 10, anchor: "start", size: 10)
        svg += rect(plot.x + 180, legendY, 12, 12, fill: palette[1], stroke: nil, opacity: 0.55)
        svg += label("Impostor (non-target) trials", x: plot.x + 198, y: legendY + 10, anchor: "start", size: 10)
        svg += label(
            "Each distribution scaled to its own total", x: plot.x + plot.width, y: legendY + 10, anchor: "end",
            size: 10)
        return svg + "</svg>\n"
    }

    // MARK: SVG primitives

    private static func header(width: Double, height: Double, title: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(fmt(width))" height="\(fmt(height))" \
        viewBox="0 0 \(fmt(width)) \(fmt(height))" font-family="-apple-system, Helvetica, Arial, sans-serif">
        <rect width="100%" height="100%" fill="#ffffff"/>
        <text x="\(fmt(width / 2))" y="22" font-size="14" font-weight="600" text-anchor="middle" fill="#111111">\(escape(title))</text>

        """
    }

    private static func rect(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double, fill: String, stroke: String?, opacity: Double = 1
    ) -> String {
        let strokeAttribute = stroke.map { " stroke=\"\($0)\"" } ?? ""
        let opacityAttribute = opacity < 1 ? " fill-opacity=\"\(fmt(opacity))\"" : ""
        return "<rect x=\"\(fmt(x))\" y=\"\(fmt(y))\" width=\"\(fmt(width))\" height=\"\(fmt(height))\" "
            + "fill=\"\(fill)\"\(strokeAttribute)\(opacityAttribute)/>\n"
    }

    private static func line(
        _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, stroke: String, width: Double = 1, dash: String? = nil
    ) -> String {
        let dashAttribute = dash.map { " stroke-dasharray=\"\($0)\"" } ?? ""
        return "<line x1=\"\(fmt(x1))\" y1=\"\(fmt(y1))\" x2=\"\(fmt(x2))\" y2=\"\(fmt(y2))\" "
            + "stroke=\"\(stroke)\" stroke-width=\"\(fmt(width))\"\(dashAttribute)/>\n"
    }

    private static func label(_ text: String, x: Double, y: Double, anchor: String, size: Double = 12) -> String {
        "<text x=\"\(fmt(x))\" y=\"\(fmt(y))\" font-size=\"\(fmt(size))\" text-anchor=\"\(anchor)\" "
            + "fill=\"#333333\">\(escape(text))</text>\n"
    }

    private static func text(tick: Double, x: Double, y: Double, anchor: String) -> String {
        let percent = tick * 100
        let text = percent < 1 ? String(format: "%.1f", percent) : String(format: "%.0f", percent)
        return label(text, x: x, y: y, anchor: anchor, size: 10)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
