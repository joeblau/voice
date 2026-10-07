/// The rule #59 uses to pick the memory embedding model, as code, so the
/// choice can be re-run as soon as the missing numbers arrive (the
/// EmbeddingGemma weights are gated; the iPhone latencies need a device).
///
/// A candidate **qualifies** when, at the stored width (256-d int8):
///
/// | Criterion | Budget | Why |
/// | --- | --- | --- |
/// | Non-finite outputs on the Neural Engine | 0 | A NaN vector silently poisons search |
/// | iPhone `embed.128tok` p95 | ≤ 50 ms | Query embedding sits on the `search_memory` tool path; indexing runs beside live ASR |
/// | Download | ≤ 400 MB | Blau already downloads ~700 MB of speech models |
///
/// Among qualifying candidates, the **smallest download** whose Recall@5 is
/// within `recallTolerance` (0.03) of the best qualifying Recall@5 wins:
/// a model twice the size has to be clearly better to be worth it.
///
/// If any number a decision depends on is missing, the verdict is
/// `.pending`, with the provisional choice: the architecture's default
/// (`TextEmbeddingModelSpec.chosen`) unless a known number already rules it
/// out.
public struct EmbeddingModelSelection: Hashable, Sendable {
    /// What is known about one candidate. `nil` means not measured yet.
    public struct Measurements: Codable, Hashable, Sendable {
        public var specID: String
        /// Recall@5 on the personal eval set at the stored width, int8.
        public var recallAt5: Double?
        /// Vectors with NaN or infinity from the Core ML model on the Neural
        /// Engine, over the eval set.
        public var nonFiniteOutputs: Int?
        /// p95 of `embed.128tok` on the slowest supported iPhone (Release).
        public var deviceP95Milliseconds: Double?
        /// Bytes the app downloads for the model (compiled model + tokenizer).
        public var downloadBytes: Int64?
        /// Runs without a Core ML model (static embeddings, OS models), so
        /// non-finite Neural Engine output and download don't apply.
        public var needsCoreMLModel: Bool

        public init(
            specID: String,
            recallAt5: Double? = nil,
            nonFiniteOutputs: Int? = nil,
            deviceP95Milliseconds: Double? = nil,
            downloadBytes: Int64? = nil,
            needsCoreMLModel: Bool = true
        ) {
            self.specID = specID
            self.recallAt5 = recallAt5
            self.nonFiniteOutputs = nonFiniteOutputs
            self.deviceP95Milliseconds = deviceP95Milliseconds
            self.downloadBytes = downloadBytes
            self.needsCoreMLModel = needsCoreMLModel
        }
    }

    public enum Verdict: Hashable, Sendable {
        case chosen(String, reasons: [String])
        case pending(provisional: String?, missing: [String])
        case noneQualifies(reasons: [String])
    }

    public var maximumDeviceP95Milliseconds: Double = 50
    public var maximumDownloadBytes: Int64 = 400_000_000
    public var recallTolerance: Double = 0.03
    public var preferred: String = TextEmbeddingModelSpec.chosen.id

    public init() {}

    /// What #59 measured on 2026-10-07 (docs/benchmarks.md, "Text embedding
    /// model"): Recall@5 at 256-d int8 on the personal eval set, Core ML
    /// numerics on the Neural Engine and download size for the best
    /// Neural Engine variant. EmbeddingGemma (gated) and every iPhone
    /// latency are still unmeasured.
    public static let measured: [Measurements] = [
        Measurements(specID: TextEmbeddingModelSpec.embeddingGemma300M.id),
        // Split model, int8 weights (442 MB) + float16 token table (311 MB).
        Measurements(
            specID: TextEmbeddingModelSpec.qwen3Embedding06B.id, recallAt5: 0.797, nonFiniteOutputs: 0,
            downloadBytes: 753_000_000),
        Measurements(
            specID: TextEmbeddingModelSpec.potionRetrieval32M.id, recallAt5: 0.620, downloadBytes: 124_000_000,
            needsCoreMLModel: false),
        Measurements(
            specID: TextEmbeddingModelSpec.nlContextualEmbedding.id, recallAt5: 0.325, needsCoreMLModel: false),
    ]

    /// Why `m` fails a budget, or an empty list if it passes every known one.
    public func disqualifications(_ m: Measurements) -> [String] {
        var reasons: [String] = []
        if let nonFinite = m.nonFiniteOutputs, nonFinite > 0, m.needsCoreMLModel {
            reasons.append("\(m.specID): \(nonFinite) non-finite vectors on the Neural Engine")
        }
        if let p95 = m.deviceP95Milliseconds, p95 > maximumDeviceP95Milliseconds {
            reasons.append("\(m.specID): iPhone p95 \(p95) ms > \(maximumDeviceP95Milliseconds) ms")
        }
        if let bytes = m.downloadBytes, bytes > maximumDownloadBytes, m.needsCoreMLModel {
            reasons.append("\(m.specID): download \(bytes / 1_000_000) MB > \(maximumDownloadBytes / 1_000_000) MB")
        }
        return reasons
    }

    /// The numbers still missing for `m`.
    public func missing(_ m: Measurements) -> [String] {
        var missing: [String] = []
        if m.recallAt5 == nil { missing.append("\(m.specID): Recall@5") }
        if m.deviceP95Milliseconds == nil { missing.append("\(m.specID): iPhone latency") }
        if m.needsCoreMLModel {
            if m.nonFiniteOutputs == nil { missing.append("\(m.specID): Neural Engine numerics") }
            if m.downloadBytes == nil { missing.append("\(m.specID): download size") }
        }
        return missing
    }

    public func evaluate(_ candidates: [Measurements]) -> Verdict {
        let ruledOut = candidates.flatMap(disqualifications)
        let viable = candidates.filter { disqualifications($0).isEmpty }
        guard !viable.isEmpty else { return .noneQualifies(reasons: ruledOut) }

        let missing = viable.flatMap(self.missing)
        if !missing.isEmpty {
            let provisional =
                viable.first { $0.specID == preferred }?.specID
                ?? viable.max { ($0.recallAt5 ?? 0) < ($1.recallAt5 ?? 0) }?.specID
            return .pending(provisional: provisional, missing: missing)
        }

        let best = viable.compactMap(\.recallAt5).max() ?? 0
        let closeEnough = viable.filter { ($0.recallAt5 ?? 0) >= best - recallTolerance }
        let winner = closeEnough.min { lhs, rhs in
            let (left, right) = (lhs.downloadBytes ?? 0, rhs.downloadBytes ?? 0)
            return left == right ? (lhs.recallAt5 ?? 0) > (rhs.recallAt5 ?? 0) : left < right
        }
        guard let winner else { return .noneQualifies(reasons: ruledOut) }
        var reasons = [
            "\(winner.specID): Recall@5 \(winner.recallAt5 ?? 0) within \(recallTolerance) of the best (\(best))"
        ]
        reasons += ruledOut
        return .chosen(winner.specID, reasons: reasons)
    }
}
