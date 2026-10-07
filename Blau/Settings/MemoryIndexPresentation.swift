import BlauMemory
import Foundation

/// User-facing text for the memory index's status (#63), shown in
/// Settings → Knowledge → Search Index.
struct MemoryIndexPresentation: Equatable {
    /// A long job and how far it has got.
    struct Job: Equatable {
        let label: String
        let fractionCompleted: Double
        /// e.g. "1,200 of 3,400".
        let count: String
    }

    /// One-line status, e.g. "Up to date".
    let title: String
    /// What the index is and what is happening to it.
    let detail: String
    /// SF Symbol name.
    let systemImage: String
    /// A rebuild or embedding in progress.
    let job: Job?
    /// Passages in the index, e.g. "1,234".
    let indexed: String?
    let lastRebuild: Date?
    /// Whether "Rebuild Index" is offered.
    let canRebuild: Bool
    /// Whether the status needs the user's attention.
    let isWarning: Bool

    init(_ status: MemoryIndexingStatus?) {
        let about = String(
            localized:
                "Blau indexes your conversations and notes on this iPhone so it can search them. The index updates as text arrives from your other devices, catches up in the background, and never leaves this device."
        )
        guard let status else {
            self.init(
                title: String(localized: "Not available"),
                detail: String(localized: "Search needs Blau's saved data. This session uses temporary storage."),
                systemImage: "magnifyingglass", job: nil, indexed: nil, lastRebuild: nil, canRebuild: false,
                isWarning: false)
            return
        }

        let job: Job? =
            if let rebuild = status.rebuild, rebuild.total > 0 {
                Job(
                    label: String(localized: "Rebuilding"), fractionCompleted: rebuild.fractionCompleted,
                    count: Self.count(rebuild))
            } else if let embedding = status.embedding {
                Job(
                    label: String(localized: "Preparing search"),
                    fractionCompleted: embedding.fractionCompleted, count: Self.count(embedding))
            } else {
                nil
            }

        var title: String
        var systemImage = "magnifyingglass"
        var isWarning = false
        var detail = about
        switch status.activity {
        case .starting:
            title = String(localized: "Starting…")
        case .idle:
            title = status.hasPendingWork ? String(localized: "Waiting") : String(localized: "Up to date")
        case .indexingChanges:
            title = String(localized: "Updating…")
        case .rebuilding:
            title = String(localized: "Rebuilding…")
        case .embedding:
            title = String(localized: "Preparing…")
        case .waiting(.suspended):
            title = String(localized: "Paused")
            systemImage = "thermometer.high"
            isWarning = true
            detail = String(
                localized:
                    "Indexing is paused while your iPhone is very hot or almost out of battery. It resumes on its own."
            )
        case .waiting:
            title = String(localized: "Waiting")
            systemImage = "thermometer.medium"
            detail = String(
                localized:
                    "Indexing is held back for a few minutes while your iPhone is warm or in Low Power Mode."
            )
        }
        if status.vectorsUnavailable != nil, status.chunkCount > 0 {
            detail +=
                " "
                + String(localized: "Until the language model is installed, search matches words rather than meaning.")
        }
        if status.lastError != nil, status.activity == .idle {
            detail += " " + String(localized: "The last update failed; Blau will try again.")
        }

        self.init(
            title: title, detail: detail, systemImage: systemImage, job: job,
            indexed: status.chunkCount.formatted(), lastRebuild: status.lastRebuild,
            canRebuild: status.rebuild == nil, isWarning: isWarning)
    }

    private init(
        title: String, detail: String, systemImage: String, job: Job?, indexed: String?, lastRebuild: Date?,
        canRebuild: Bool, isWarning: Bool
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.job = job
        self.indexed = indexed
        self.lastRebuild = lastRebuild
        self.canRebuild = canRebuild
        self.isWarning = isWarning
    }

    private static func count(_ progress: MemoryIndexingProgress) -> String {
        String(localized: "\(progress.completed.formatted()) of \(progress.total.formatted())")
    }
}
