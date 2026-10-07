import Foundation

/// Where one model is in its lifecycle.
///
///     notDownloaded ─▶ queued ─▶ downloading ─▶ preparing ─▶ ready
///                        ▲  │          │             │
///                        │  ▼          ▼             ▼
///                       waiting(for:)            failed
public enum ModelState: Hashable, Sendable {
    /// Not on the device and not scheduled (an optional model, or one the
    /// user deleted).
    case notDownloaded
    /// Scheduled to download.
    case queued
    /// Scheduled, but the network doesn't allow downloading right now.
    /// Resumes on its own when it does.
    case waiting(for: NetworkRequirement)
    /// Bytes on disk so far.
    case downloading(bytesReceived: Int64, totalBytes: Int64)
    /// Downloaded and verified; being loaded for the first time on this OS
    /// version (the Neural Engine compile).
    case preparing
    /// Installed and loadable.
    case ready
    case failed(ModelFailure)

    /// Whether the model's files are installed.
    public var isInstalled: Bool {
        switch self {
        case .preparing, .ready: true
        default: false
        }
    }

    /// Download progress in `0...1`, if downloading.
    public var downloadFraction: Double? {
        guard case .downloading(let received, let total) = self else { return nil }
        return total > 0 ? min(1, Double(received) / Double(total)) : 0
    }
}

/// The kind of network a waiting download needs.
public enum NetworkRequirement: Hashable, Sendable {
    /// Any internet connection.
    case connection
    /// Wi-Fi or Ethernet (not cellular, a hotspot, or Low Data Mode), under
    /// the Wi-Fi-only policy.
    case unmeteredNetwork
}

/// Why a model isn't usable.
public enum ModelFailure: Hashable, Sendable {
    case download(ModelDownloadError)
    /// The files are intact but Core ML couldn't load them on this device.
    case loadFailed(String)

    /// A sentence for the user.
    public var message: String {
        switch self {
        case .download(.insufficientStorage(let required, _)):
            let size = required.formatted(.byteCount(style: .file))
            return "Not enough free space. Free up \(size) and try again."
        case .download(.checksumMismatch):
            return "A downloaded file was damaged. Try again."
        case .download(.server(let status, _)):
            return "The model server returned an error (\(status)). Try again later."
        case .download(.transferFailed):
            return "The download kept failing. Check your connection and try again."
        case .download(.storage):
            return "Couldn't save the model. Check free space and try again."
        case .download(.offline):
            return "You're offline."
        case .download(.requiresUnmeteredNetwork):
            return "Waiting for Wi-Fi."
        case .loadFailed:
            return "This model couldn't be loaded on this device."
        }
    }
}

/// Progress of the required models, for onboarding.
public struct ModelSetupStatus: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// The manager hasn't looked at what is installed yet.
        case checking
        /// A required model isn't on the device and isn't scheduled.
        case needsDownload
        case downloading
        case waiting(for: NetworkRequirement)
        /// Everything is downloaded; first loads are compiling.
        case preparing
        case ready
        case failed(ModelID, ModelFailure)
    }

    public var phase: Phase
    /// Bytes of the required models on disk.
    public var bytesReceived: Int64
    /// Total size of the required models.
    public var totalBytes: Int64

    /// Download progress in `0...1`.
    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(bytesReceived) / Double(totalBytes)) : 1
    }
}
