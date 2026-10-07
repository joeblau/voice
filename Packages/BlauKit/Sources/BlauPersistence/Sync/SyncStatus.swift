import Foundation

/// What CloudKit mirroring has been doing, folded from `CloudSyncEvent`s.
public struct CloudSyncActivity: Sendable, Equatable {
    /// Events that started and haven't finished.
    public private(set) var inProgress: [UUID: CloudSyncEvent.Kind] = [:]
    /// When the last successful import (changes from other devices) ended.
    public private(set) var lastImport: Date?
    /// When the last successful export (changes from this device) ended.
    public private(set) var lastExport: Date?
    /// The error of the most recent failed event, cleared by the next
    /// successful one.
    public private(set) var lastError: CloudSyncError?

    public init() {}

    /// Whether an import or export is running.
    public var isSyncing: Bool {
        inProgress.values.contains { $0 == .import || $0 == .export }
    }

    /// When data last moved successfully in either direction.
    public var lastSuccessfulSync: Date? {
        [lastImport, lastExport].compactMap { $0 }.max()
    }

    public mutating func record(_ event: CloudSyncEvent) {
        guard let endDate = event.endDate else {
            inProgress[event.id] = event.kind
            return
        }
        inProgress[event.id] = nil
        guard event.succeeded else {
            lastError = event.error ?? CloudSyncError(domain: "Blau", code: 0, message: "Sync failed")
            return
        }
        lastError = nil
        switch event.kind {
        case .import: lastImport = max(lastImport ?? endDate, endDate)
        case .export: lastExport = max(lastExport ?? endDate, endDate)
        case .setup, .unknown: break
        }
    }
}

/// The iCloud sync state to show in Settings.
public enum SyncState: Sendable, Equatable {
    /// Waiting for the iCloud account status at launch.
    case checking
    /// Sync is on and an import or export is running.
    case syncing(lastSync: Date?)
    /// Sync is on and idle. `lastSync` is `nil` until the first transfer.
    case upToDate(lastSync: Date?)
    /// Sync is on but the last attempt failed. It retries on its own.
    case failing(CloudSyncError, lastSync: Date?)
    /// Data stays on this device.
    case off(SyncOffReason)
    /// Nothing is saved: the store is in memory.
    case notSaved(storeFailed: Bool)

    /// Folds the store's mode, the account and mirroring activity into one
    /// state.
    public init(mode: SyncMode?, accountStatus: CloudAccountStatus?, activity: CloudSyncActivity) {
        switch mode {
        case nil:
            self = .checking
        case .cloudKit:
            if let error = activity.lastError {
                self = .failing(error, lastSync: activity.lastSuccessfulSync)
            } else if activity.isSyncing {
                self = .syncing(lastSync: activity.lastSuccessfulSync)
            } else {
                self = .upToDate(lastSync: activity.lastSuccessfulSync)
            }
        case .localOnly(let reason):
            switch reason {
            case .account(let status): self = .off(SyncOffReason(accountStatus ?? status))
            case .notEntitled: self = .off(.notAvailableInThisBuild)
            case .forced: self = .off(.disabledForDevelopment)
            case .cloudKitFailed(let message): self = .off(.storeError(message))
            }
        case .inMemory(let reason):
            if case .storeFailed = reason {
                self = .notSaved(storeFailed: true)
            } else {
                self = .notSaved(storeFailed: false)
            }
        }
    }
}

/// Why iCloud sync is off.
public enum SyncOffReason: Sendable, Equatable {
    /// Not signed in to iCloud, or iCloud is off for Blau.
    case signedOut
    /// Screen Time or device management blocks iCloud.
    case restricted
    /// The account needs attention in the Settings app.
    case temporarilyUnavailable
    /// The account status couldn't be read; Blau retries.
    case unknown
    /// This build has no iCloud entitlement (unsigned simulator / CI build).
    case notAvailableInThisBuild
    /// Turned off with `-BlauStore local`.
    case disabledForDevelopment
    /// CloudKit couldn't open the store; Blau retries next launch.
    case storeError(String)

    init(_ status: CloudAccountStatus) {
        switch status {
        case .noAccount: self = .signedOut
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine, .available: self = .unknown
        }
    }

    /// Whether the user can fix it in the Settings app.
    public var isUserFixable: Bool {
        switch self {
        case .signedOut, .temporarilyUnavailable: true
        default: false
        }
    }
}
