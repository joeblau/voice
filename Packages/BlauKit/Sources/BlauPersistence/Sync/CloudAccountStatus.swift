import BlauCore
import CloudKit
import Foundation
import os

/// The iCloud account state as far as Blau's CloudKit container is concerned.
///
/// A Sendable mirror of `CKAccountStatus`, so the rest of BlauKit and the UI
/// never import CloudKit.
public enum CloudAccountStatus: String, Sendable, Hashable, CaseIterable {
    /// Signed in to iCloud with iCloud enabled for Blau. Sync runs.
    case available
    /// No iCloud account on the device (or iCloud is off for Blau).
    case noAccount
    /// Parental controls or device management block iCloud.
    case restricted
    /// Signed in, but iCloud needs attention (for example a new password).
    case temporarilyUnavailable
    /// The status couldn't be read (error, timeout, or a status this build
    /// doesn't know).
    case couldNotDetermine

    public init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    /// Whether CloudKit mirroring can run with this status.
    public var allowsSync: Bool { self == .available }
}

/// Reads the iCloud account status. The app uses
/// `CloudKitAccountStatusProvider`; tests pass a fake.
public protocol CloudAccountStatusProviding: Sendable {
    /// The current account status.
    func accountStatus() async throws -> CloudAccountStatus

    /// Fires each time the device's iCloud account changes (sign in, sign
    /// out, switch account).
    func accountChanges() -> AsyncStream<Void>
}

extension CloudAccountStatusProviding {
    /// The account status, or `.couldNotDetermine` if reading it fails or
    /// takes longer than `timeout` on `clock`. Launch waits on this, so it
    /// must never hang.
    ///
    /// `CKContainer.accountStatus()` doesn't react to cancellation (a cold
    /// `cloudd` can take many seconds), so the query isn't awaited past the
    /// deadline: it runs in its own task and its late answer is dropped.
    public func accountStatus(timeout: Duration, clock: any BlauClock) async -> CloudAccountStatus {
        let (outcomes, continuation) = AsyncStream.makeStream(of: AccountStatusOutcome.self)
        let query = Task {
            do {
                continuation.yield(.status(try await accountStatus()))
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }
        }
        let timer = Task {
            try await clock.sleep(for: timeout)
            continuation.yield(.timedOut)
        }
        defer {
            query.cancel()
            timer.cancel()
            continuation.finish()
        }

        var iterator = outcomes.makeAsyncIterator()
        switch await iterator.next() {
        case .status(let status):
            return status
        case .failed(let message):
            PersistenceLog.logger.error("iCloud account status failed: \(message, privacy: .public)")
            return .couldNotDetermine
        case .timedOut, nil:
            PersistenceLog.logger.error("iCloud account status timed out")
            return .couldNotDetermine
        }
    }
}

/// The first thing to happen while waiting for the account status.
private enum AccountStatusOutcome: Sendable {
    case status(CloudAccountStatus)
    case failed(String)
    case timedOut
}

/// Reads the account status from `CKContainer`.
///
/// Only create one in a build that has the iCloud entitlement:
/// `CKContainer(identifier:)` raises an exception in an app without it (for
/// example an unsigned simulator build). `PersistenceController` checks
/// `PersistenceOptions.cloudKitEntitled` before it asks.
public struct CloudKitAccountStatusProvider: CloudAccountStatusProviding {
    public let containerIdentifier: String
    private let notificationCenter: NotificationCenter

    public init(
        containerIdentifier: String = BlauCloud.containerIdentifier,
        notificationCenter: NotificationCenter = .default
    ) {
        self.containerIdentifier = containerIdentifier
        self.notificationCenter = notificationCenter
    }

    public func accountStatus() async throws -> CloudAccountStatus {
        CloudAccountStatus(try await CKContainer(identifier: containerIdentifier).accountStatus())
    }

    public func accountChanges() -> AsyncStream<Void> {
        notificationCenter.signals(named: .CKAccountChanged)
    }
}
