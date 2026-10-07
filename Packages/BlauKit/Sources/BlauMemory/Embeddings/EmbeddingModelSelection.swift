/// The rule #59 uses to pick the memory embedding model, as code, so the
/// choice can be re-run as soon as the missing numbers arrive (the
/// EmbeddingGemma weights are gated; the iPhone latencies need a device).
///
/// Only **memory candidates** (`Measurements.Role.memoryCandidate`) take
/// part. Baselines (Apple's `NLContextualEmbedding`) and the CPU fallback
/// (potion-retrieval-32M) are measured for comparison but are never
/// selected and never hold the verdict at `.pending`.
///
/// A memory candidate **qualifies** when, at the stored width (256-d int8):
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
///
/// If **no** memory candidate qualifies, the verdict is `.fallback` to
/// `fallback` (Qwen3-Embedding-0.6B) as long as its vectors are finite: it
/// may break the latency or download budget, and those breaches are listed
/// in the verdict's reasons, because adopting it means the owner raises the
/// budget (`maximumDownloadBytes`, `maximumDeviceP95Milliseconds`). With a
/// raised budget it qualifies and the rule returns `.chosen` for it.
public struct EmbeddingModelSelection: Hashable, Sendable {
    /// What is known about one candidate. `nil` means not measured yet.
    public struct Measurements: Codable, Hashable, Sendable {
        /// Whether a model takes part in the selection.
        public enum Role: String, Codable, Hashable, Sendable {
            /// Can be selected as the memory embedding model.
            case memoryCandidate
            /// Measured for comparison only (`NLContextualEmbedding`).
            case baseline
            /// A static CPU embedder kept for when the Neural Engine is
            /// unavailable (potion-retrieval-32M, #26); not a memory model.
            case cpuFallback
        }

        public var specID: String
        public var role: Role
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
            role: Role = .memoryCandidate,
            recallAt5: Double? = nil,
            nonFiniteOutputs: Int? = nil,
            deviceP95Milliseconds: Double? = nil,
            downloadBytes: Int64? = nil,
            needsCoreMLModel: Bool = true
        ) {
            self.specID = specID
            self.role = role
            self.recallAt5 = recallAt5
            self.nonFiniteOutputs = nonFiniteOutputs
            self.deviceP95Milliseconds = deviceP95Milliseconds
            self.downloadBytes = downloadBytes
            self.needsCoreMLModel = needsCoreMLModel
        }

        private enum CodingKeys: String, CodingKey {
            case specID, role, recallAt5, nonFiniteOutputs, deviceP95Milliseconds, downloadBytes, needsCoreMLModel
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                specID: try container.decode(String.self, forKey: .specID),
                role: try container.decodeIfPresent(Role.self, forKey: .role) ?? .memoryCandidate,
                recallAt5: try container.decodeIfPresent(Double.self, forKey: .recallAt5),
                nonFiniteOutputs: try container.decodeIfPresent(Int.self, forKey: .nonFiniteOutputs),
                deviceP95Milliseconds: try container.decodeIfPresent(Double.self, forKey: .deviceP95Milliseconds),
                downloadBytes: try container.decodeIfPresent(Int64.self, forKey: .downloadBytes),
                needsCoreMLModel: try container.decodeIfPresent(Bool.self, forKey: .needsCoreMLModel) ?? true)
        }
    }

    public enum Verdict: Hashable, Sendable {
        /// `id` qualifies on every budget and wins on Recall@5 and size.
        case chosen(String, reasons: [String])
        /// A number the decision depends on is missing.
        case pending(provisional: String?, missing: [String])
        /// No memory candidate qualifies; `id` is the documented fallback.
        /// `reasons` lists why each candidate was ruled out, including the
        /// budgets the fallback itself breaks (the owner has to raise them to
        /// adopt it); `missing` lists the fallback's numbers still unmeasured.
        case fallback(String, reasons: [String], missing: [String])
        /// No memory candidate qualifies and the fallback can't be used
        /// either (absent, or non-finite vectors).
        case noneQualifies(reasons: [String])
    }

    public var maximumDeviceP95Milliseconds: Double = 50
    public var maximumDownloadBytes: Int64 = 400_000_000
    public var recallTolerance: Double = 0.03
    public var preferred: String = TextEmbeddingModelSpec.chosen.id
    /// The model to fall back to when no memory candidate qualifies
    /// (docs/benchmarks.md, "Text embedding model", decision 2).
    public var fallback: String? = TextEmbeddingModelSpec.qwen3Embedding06B.id

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
            specID: TextEmbeddingModelSpec.potionRetrieval32M.id, role: .cpuFallback, recallAt5: 0.620,
            downloadBytes: 124_000_000, needsCoreMLModel: false),
        Measurements(
            specID: TextEmbeddingModelSpec.nlContextualEmbedding.id, role: .baseline, recallAt5: 0.325,
            needsCoreMLModel: false),
    ]

    /// Why `m` fails a budget, or an empty list if it passes every known one.
    public func disqualifications(_ m: Measurements) -> [String] {
        unusable(m) + overBudget(m)
    }

    /// Failures no budget change can fix.
    private func unusable(_ m: Measurements) -> [String] {
        if let nonFinite = m.nonFiniteOutputs, nonFinite > 0, m.needsCoreMLModel {
            return ["\(m.specID): \(nonFinite) non-finite vectors on the Neural Engine"]
        }
        return []
    }

    /// Failures the owner can accept by raising a budget.
    private func overBudget(_ m: Measurements) -> [String] {
        var reasons: [String] = []
        if let p95 = m.deviceP95Milliseconds, p95 > maximumDeviceP95Milliseconds {
            reasons.append("\(m.specID): iPhone p95 \(p95) ms > \(maximumDeviceP95Milliseconds) ms")
        }
        if let bytes = m.downloadBytes, bytes > maximumDownloadBytes, m.needsCoreMLModel {
            reasons.append("\(m.specID): download \(bytes / 1_000_000) MB > \(maximumDownloadBytes / 1_000_000) MB")
        }
        return reasons
    }

    /// The numbers the decision still needs from `m`. Baselines and the CPU
    /// fallback don't take part in the decision, so they never need any.
    public func missing(_ m: Measurements) -> [String] {
        guard m.role == .memoryCandidate else { return [] }
        var missing: [String] = []
        if m.recallAt5 == nil { missing.append("\(m.specID): Recall@5") }
        if m.deviceP95Milliseconds == nil { missing.append("\(m.specID): iPhone latency") }
        if m.needsCoreMLModel {
            if m.nonFiniteOutputs == nil { missing.append("\(m.specID): Neural Engine numerics") }
            if m.downloadBytes == nil { missing.append("\(m.specID): download size") }
        }
        return missing
    }

    public func evaluate(_ measurements: [Measurements]) -> Verdict {
        let candidates = measurements.filter { $0.role == .memoryCandidate }
        let ruledOut = candidates.flatMap(disqualifications)
        let viable = candidates.filter { disqualifications($0).isEmpty }
        guard !viable.isEmpty else { return fallbackVerdict(candidates, ruledOut: ruledOut) }

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

    /// Every memory candidate is ruled out: fall back to `fallback` if it was
    /// only ruled out by a budget.
    private func fallbackVerdict(_ candidates: [Measurements], ruledOut: [String]) -> Verdict {
        guard let fallback, let model = candidates.first(where: { $0.specID == fallback }),
            unusable(model).isEmpty
        else { return .noneQualifies(reasons: ruledOut) }
        return .fallback(model.specID, reasons: ruledOut, missing: missing(model))
    }
}
