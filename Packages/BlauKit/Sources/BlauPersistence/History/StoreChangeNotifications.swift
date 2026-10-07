import CoreData
import Foundation

/// Signals that another coordinator (CloudKit mirroring importing changes
/// from another device, an extension, a background `ModelActor` on a separate
/// coordinator) wrote to the synced store.
///
/// Core Data posts `NSPersistentStoreRemoteChange` for every store that has
/// remote change notifications on, so the stream keeps only the ones for
/// `storeURL`. A signal says "something changed"; read the details with a
/// `PersistentHistoryTracker`.
public struct RemoteChangeMonitor: Sendable {
    /// Core Data's user-info key for the URL of the store that changed.
    static let storeURLKey = "storeURL"

    public let storeURL: URL
    private let notificationCenter: NotificationCenter

    public init(storeURL: URL, notificationCenter: NotificationCenter = .default) {
        self.storeURL = storeURL
        self.notificationCenter = notificationCenter
    }

    /// One signal per relevant notification. Bursts coalesce: a consumer
    /// that falls behind sees at most one pending signal.
    public func changes() -> AsyncStream<Void> {
        let storeURL = storeURL
        return notificationCenter.stream(named: .NSPersistentStoreRemoteChange, bufferingPolicy: .bufferingNewest(1)) {
            Self.matches($0.userInfo?[Self.storeURLKey] as? URL, storeURL: storeURL) ? () : nil
        }
    }

    /// Whether a notification about `notified` concerns `storeURL`. A
    /// notification without a URL is kept: missing a change is worse than
    /// one extra history read.
    static func matches(_ notified: URL?, storeURL: URL) -> Bool {
        guard let notified else { return true }
        return notified.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            == storeURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}

/// One CloudKit mirroring event (setup, import or export) reported by
/// `NSPersistentCloudKitContainer`, which SwiftData uses under the hood.
public struct CloudSyncEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case setup
        case `import`
        case export
        case unknown
    }

    /// Stays the same between an event's start and finish notifications.
    public let id: UUID
    public let kind: Kind
    public let storeIdentifier: String
    public let startDate: Date
    /// `nil` while the event is in progress.
    public let endDate: Date?
    public let succeeded: Bool
    public let error: CloudSyncError?

    public init(
        id: UUID,
        kind: Kind,
        storeIdentifier: String = "",
        startDate: Date,
        endDate: Date?,
        succeeded: Bool,
        error: CloudSyncError? = nil
    ) {
        self.id = id
        self.kind = kind
        self.storeIdentifier = storeIdentifier
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.error = error
    }

    init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind =
            switch event.type {
            case .setup: .setup
            case .import: .import
            case .export: .export
            @unknown default: .unknown
            }
        self.init(
            id: event.identifier,
            kind: kind,
            storeIdentifier: event.storeIdentifier,
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            error: event.error.map { CloudSyncError($0 as NSError) }
        )
    }

    /// Whether the event has finished (successfully or not).
    public var isFinished: Bool { endDate != nil }

    /// Every CloudKit mirroring event posted on `notificationCenter`.
    public static func events(notificationCenter: NotificationCenter = .default) -> AsyncStream<CloudSyncEvent> {
        notificationCenter.stream(named: NSPersistentCloudKitContainer.eventChangedNotification) { notification in
            (notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event).map(CloudSyncEvent.init)
        }
    }
}

/// A Sendable summary of a CloudKit sync error.
public struct CloudSyncError: Sendable, Hashable, Error {
    /// `CKErrorDomain` codes Blau treats specially. Values from `CKError.Code`.
    enum CloudKitCode: Int {
        case networkUnavailable = 3
        case networkFailure = 4
        case notAuthenticated = 9
        case quotaExceeded = 25
        case partialFailure = 2
    }

    public static let cloudKitDomain = "CKErrorDomain"

    public let domain: String
    public let code: Int
    public let message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    init(_ error: NSError) {
        // Mirroring often wraps the CloudKit error that explains the failure.
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == Self.cloudKitDomain ? $0 : nil
        }
        let source = error.domain == Self.cloudKitDomain ? error : (underlying ?? error)
        self.init(domain: source.domain, code: source.code, message: source.localizedDescription)
    }

    private func isCloudKit(_ code: CloudKitCode) -> Bool {
        domain == Self.cloudKitDomain && self.code == code.rawValue
    }

    /// The user's iCloud storage is full.
    public var isQuotaExceeded: Bool { isCloudKit(.quotaExceeded) }

    /// No network; sync resumes on its own.
    public var isNetworkProblem: Bool { isCloudKit(.networkUnavailable) || isCloudKit(.networkFailure) }

    /// The iCloud account needs the user's attention.
    public var isNotAuthenticated: Bool { isCloudKit(.notAuthenticated) }
}
