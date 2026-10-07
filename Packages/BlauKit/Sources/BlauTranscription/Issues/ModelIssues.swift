import BlauCore
import Foundation

extension ModelFailure {
    /// The catalog entry for this failure (#80, docs/errors.md).
    public var issue: UserFacingIssue {
        switch self {
        case .download(.insufficientStorage(let required, _)):
            let size = required.formatted(.byteCount(style: .file))
            return UserFacingIssue(
                .modelsStorageFull, message: "Not enough free space. Free up \(size) and try again.")
        case .download(.checksumMismatch):
            return UserFacingIssue(.modelDamaged)
        case .download(.server(let status, _)):
            return UserFacingIssue(
                .modelDownloadFailed, message: "The model server returned an error (\(status)). Try again later.")
        case .download(.transferFailed):
            return UserFacingIssue(.modelDownloadFailed)
        case .download(.storage):
            return UserFacingIssue(
                .modelsStorageFull, message: "Couldn't save the model. Check free space and try again.")
        case .download(.offline):
            return UserFacingIssue(.modelsWaitingForNetwork)
        case .download(.requiresUnmeteredNetwork):
            return UserFacingIssue(.modelsWaitingForWiFi)
        case .loadFailed:
            return UserFacingIssue(.modelLoadFailed)
        }
    }
}

extension ModelSetupStatus {
    /// What to tell the user about the required speech models, or `nil`
    /// while they are being checked, downloaded or prepared, are ready, or
    /// wait for the user to start the download (onboarding asks for that).
    public var issue: UserFacingIssue? {
        switch phase {
        case .checking, .needsDownload, .downloading, .preparing, .ready:
            nil
        case .waiting(.connection):
            UserFacingIssue(.modelsWaitingForNetwork)
        case .waiting(.unmeteredNetwork):
            UserFacingIssue(.modelsWaitingForWiFi)
        case .failed(let id, let failure):
            failure.issue.withMessage("\(id.displayName): \(failure.issue.message)")
        }
    }
}
