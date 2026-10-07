import BlauPersistence
import Foundation

/// User-facing text and symbol for a `SyncState`.
struct SyncStatusPresentation: Equatable {
    /// One-line status, e.g. "On" or "Off".
    let title: String
    /// What it means for the user's data.
    let detail: String
    /// SF Symbol name.
    let systemImage: String
    /// When data last moved to or from iCloud, if known.
    let lastSync: Date?
    /// Whether to offer "Open Settings" (the user can fix it there).
    let offersSettings: Bool
    /// Whether the status needs the user's attention.
    let isWarning: Bool

    init(_ state: SyncState) {
        switch state {
        case .checking:
            self.init(
                title: String(localized: "Checking…"),
                detail: String(localized: "Checking your iCloud account."),
                systemImage: "icloud", lastSync: nil)
        case .syncing(let lastSync):
            self.init(
                title: String(localized: "Syncing…"),
                detail: String(
                    localized: "Conversations and your voiceprint sync to your other devices through iCloud."),
                systemImage: "arrow.triangle.2.circlepath.icloud", lastSync: lastSync)
        case .upToDate(let lastSync):
            self.init(
                title: String(localized: "On"),
                detail: String(
                    localized: "Conversations and your voiceprint sync to your other devices through iCloud."),
                systemImage: "checkmark.icloud", lastSync: lastSync)
        case .failing(let error, let lastSync):
            self.init(
                title: String(localized: "Paused"),
                detail: Self.detail(for: error),
                systemImage: "exclamationmark.icloud", lastSync: lastSync, isWarning: true)
        case .off(let reason):
            self.init(
                title: String(localized: "Off"),
                detail: Self.detail(for: reason),
                systemImage: "icloud.slash", lastSync: nil,
                offersSettings: reason.isUserFixable, isWarning: reason.isUserFixable)
        case .notSaved(let storeFailed):
            self.init(
                title: String(localized: "Not saving"),
                detail: storeFailed
                    ? String(
                        localized:
                            "Blau couldn't open its database. New conversations won't be kept until it restarts. Your existing data is untouched."
                    )
                    : String(localized: "This session uses temporary storage; nothing is saved."),
                systemImage: "exclamationmark.triangle", lastSync: nil, isWarning: storeFailed)
        }
    }

    private init(
        title: String,
        detail: String,
        systemImage: String,
        lastSync: Date?,
        offersSettings: Bool = false,
        isWarning: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.lastSync = lastSync
        self.offersSettings = offersSettings
        self.isWarning = isWarning
    }

    private static let keptOnDevice = String(
        localized: "Everything is saved on this iPhone and syncs once iCloud is available again.")

    private static func detail(for reason: SyncOffReason) -> String {
        switch reason {
        case .signedOut:
            String(localized: "You're not signed in to iCloud, or iCloud is off for Blau.") + " " + keptOnDevice
        case .restricted:
            String(localized: "iCloud is restricted on this iPhone.") + " " + keptOnDevice
        case .temporarilyUnavailable:
            String(localized: "Your iCloud account needs attention in Settings.") + " " + keptOnDevice
        case .unknown:
            String(localized: "Blau couldn't reach your iCloud account and will try again.") + " " + keptOnDevice
        case .notAvailableInThisBuild:
            String(localized: "This build of Blau isn't signed for iCloud.") + " " + keptOnDevice
        case .disabledForDevelopment:
            String(localized: "iCloud sync is turned off for development.") + " " + keptOnDevice
        case .storeError:
            String(localized: "iCloud sync couldn't start; Blau will try again next launch.") + " " + keptOnDevice
        }
    }

    private static func detail(for error: CloudSyncError) -> String {
        if error.isQuotaExceeded {
            String(localized: "Your iCloud storage is full. New changes stay on this iPhone until you free up space.")
        } else if error.isNetworkProblem {
            String(localized: "No connection to iCloud. Changes sync when you're back online.")
        } else if error.isNotAuthenticated {
            String(localized: "Your iCloud account needs attention in Settings.")
        } else {
            String(localized: "iCloud sync hit a problem and will retry. Your data is safe on this iPhone.")
        }
    }
}

extension CloudAccountStatus {
    /// The account status as shown in Settings.
    var localizedDescription: String {
        switch self {
        case .available: String(localized: "Signed in")
        case .noAccount: String(localized: "Not signed in")
        case .restricted: String(localized: "Restricted")
        case .temporarilyUnavailable: String(localized: "Needs attention")
        case .couldNotDetermine: String(localized: "Unknown")
        }
    }
}
