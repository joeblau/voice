import BlauCore
import Foundation

extension SyncState {
    /// What the user should know about iCloud sync and the store (#80,
    /// docs/errors.md), or `nil` when there is nothing to say.
    ///
    /// Only problems worth showing during a conversation become issues: a
    /// full iCloud, an account that needs the user, a store that couldn't
    /// open. Sync that is off by design in this build (unsigned, forced
    /// local) and network failures (the conversation's own banner says
    /// "offline") stay in Settings → iCloud.
    public var issue: UserFacingIssue? {
        switch self {
        case .checking, .syncing, .upToDate:
            nil
        case .failing(let error, _):
            if error.isQuotaExceeded {
                UserFacingIssue(.iCloudFull)
            } else if error.isNotAuthenticated {
                UserFacingIssue(.iCloudUnavailable)
            } else if error.isNetworkProblem {
                nil
            } else {
                UserFacingIssue(.iCloudSyncPaused)
            }
        case .off(let reason):
            reason.isUserFixable ? UserFacingIssue(.iCloudUnavailable) : nil
        case .notSaved(let storeFailed):
            storeFailed ? UserFacingIssue(.storeUnavailable) : nil
        }
    }
}
