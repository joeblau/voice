import Foundation

/// The error catalog (#80): every kind of problem Blau tells the user
/// about, with its wording, severity and recovery actions.
///
/// The raw values are stable identifiers: they appear in logs and in
/// docs/errors.md, which lists every case (a test keeps the two in step).
/// Add a case here, map the failure to it in its module, and document it
/// in the catalog.
public enum IssueCode: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    // MARK: Connection to Grok
    /// The device has no internet connection.
    case offline = "connection.offline"
    /// The realtime connection dropped and is being reopened.
    case reconnecting = "connection.reconnecting"
    /// Blau gave up reopening the connection for now (it tries again).
    case grokUnreachable = "connection.unreachable"
    /// TLS failed: a captive portal, a VPN, or the wrong date and time.
    case secureConnectionFailed = "connection.insecure"
    /// xAI is rate limiting the user's key (HTTP 429 or a rate-limit error).
    case rateLimited = "connection.rateLimited"
    /// xAI returned a server error (HTTP 5xx, `internal_error`).
    case xaiServerError = "connection.serverError"

    // MARK: xAI account
    /// No xAI API key is stored.
    case missingAPIKey = "account.missingKey"
    /// xAI rejected the key (HTTP 401, or the upgrade refused twice).
    case invalidAPIKey = "account.invalidKey"
    /// The key or its team is blocked or disabled.
    case apiKeyDisabled = "account.keyDisabled"
    /// The key's team has no credits left or hit its spending limit.
    case insufficientCredits = "account.noCredits"
    /// The key may not use the realtime voice API (HTTP 403).
    case voiceNotPermitted = "account.notPermitted"
    /// The Keychain is locked (device locked since restart).
    case keychainLocked = "account.keychainLocked"
    /// The Keychain failed or the stored key is unreadable.
    case keychainFailure = "account.keychainFailure"

    // MARK: Replies
    /// Grok reported the response as failed, or rejected the request.
    case replyFailed = "reply.failed"
    /// No `response.created` within the response timeout.
    case replyTimedOut = "reply.timedOut"
    /// A protocol or request error: a bug in Blau or an API change.
    case unexpectedResponse = "reply.unexpected"

    // MARK: Microphone and audio
    /// The user denied microphone access.
    case microphoneDenied = "audio.microphoneDenied"
    /// The input route went away and no other route can record (mic route
    /// lost: `noSuitableRouteForCategory`).
    case microphoneUnavailable = "audio.routeLost"
    /// Activation failed because something else holds the microphone.
    case microphoneBusy = "audio.microphoneBusy"
    /// A call, Siri or another app interrupted the session.
    case audioInterrupted = "audio.interrupted"
    /// Audio stopped off screen and waits for the user.
    case audioPaused = "audio.paused"
    /// Audio stopped flowing; the graph is being rebuilt.
    case audioRecovering = "audio.recovering"
    /// The audio session or engine couldn't start.
    case audioFailed = "audio.failed"

    // MARK: Speech models
    /// A model download waits for an internet connection.
    case modelsWaitingForNetwork = "models.waitingForNetwork"
    /// A model download waits for Wi-Fi under the Wi-Fi-only policy.
    case modelsWaitingForWiFi = "models.waitingForWiFi"
    /// Not enough free space for the models.
    case modelsStorageFull = "models.storageFull"
    /// Retries ran out, or the model server refused a file.
    case modelDownloadFailed = "models.downloadFailed"
    /// A downloaded file kept failing its checksum.
    case modelDamaged = "models.damaged"
    /// Core ML couldn't load an installed model.
    case modelLoadFailed = "models.loadFailed"

    // MARK: Storage and iCloud
    /// The user's iCloud storage is full (`CKError.quotaExceeded`).
    case iCloudFull = "storage.iCloudFull"
    /// The user isn't signed in to iCloud (or iCloud is off for Blau).
    case iCloudUnavailable = "storage.iCloudUnavailable"
    /// iCloud sync failed for another reason and will retry.
    case iCloudSyncPaused = "storage.syncPaused"
    /// A transcript write failed.
    case transcriptNotSaved = "storage.transcriptNotSaved"
    /// The database couldn't be opened; nothing is saved.
    case storeUnavailable = "storage.unavailable"

    public var description: String { rawValue }

    /// The subsystem the issue belongs to.
    public var area: IssueArea {
        switch self {
        case .offline, .reconnecting, .grokUnreachable, .secureConnectionFailed, .rateLimited, .xaiServerError:
            .connection
        case .missingAPIKey, .invalidAPIKey, .apiKeyDisabled, .insufficientCredits, .voiceNotPermitted,
            .keychainLocked, .keychainFailure:
            .account
        case .replyFailed, .replyTimedOut, .unexpectedResponse:
            .replies
        case .microphoneDenied, .microphoneUnavailable, .microphoneBusy, .audioInterrupted, .audioPaused,
            .audioRecovering, .audioFailed:
            .audio
        case .modelsWaitingForNetwork, .modelsWaitingForWiFi, .modelsStorageFull, .modelDownloadFailed,
            .modelDamaged, .modelLoadFailed:
            .speechModels
        case .iCloudFull, .iCloudUnavailable, .iCloudSyncPaused, .transcriptNotSaved, .storeUnavailable:
            .storage
        }
    }

    public var severity: IssueSeverity {
        switch self {
        case .offline, .reconnecting, .audioInterrupted, .audioRecovering, .modelsWaitingForNetwork,
            .modelsWaitingForWiFi, .iCloudUnavailable, .iCloudSyncPaused:
            .info
        case .grokUnreachable, .secureConnectionFailed, .rateLimited, .xaiServerError, .keychainLocked,
            .replyFailed, .replyTimedOut, .unexpectedResponse, .microphoneUnavailable, .microphoneBusy,
            .audioPaused, .audioFailed, .iCloudFull, .transcriptNotSaved:
            .warning
        case .missingAPIKey, .invalidAPIKey, .apiKeyDisabled, .insufficientCredits, .voiceNotPermitted,
            .keychainFailure, .microphoneDenied, .modelsStorageFull, .modelDownloadFailed, .modelDamaged,
            .modelLoadFailed, .storeUnavailable:
            .blocking
        }
    }

    public var title: String {
        switch self {
        case .offline: "You're offline"
        case .reconnecting: "Reconnecting to Grok…"
        case .grokUnreachable: "Can't reach Grok"
        case .secureConnectionFailed: "Secure connection failed"
        case .rateLimited: "Grok is busy"
        case .xaiServerError: "xAI is having problems"
        case .missingAPIKey: "Connect your xAI account"
        case .invalidAPIKey: "xAI didn't accept your key"
        case .apiKeyDisabled: "Your xAI key is switched off"
        case .insufficientCredits: "No xAI credits left"
        case .voiceNotPermitted: "Your key can't use voice"
        case .keychainLocked: "Unlock your iPhone"
        case .keychainFailure: "Couldn't read your xAI key"
        case .replyFailed: "Grok couldn't answer"
        case .replyTimedOut: "No answer from Grok"
        case .unexpectedResponse: "Something went wrong"
        case .microphoneDenied: "Microphone access is off"
        case .microphoneUnavailable: "No microphone"
        case .microphoneBusy: "Microphone in use"
        case .audioInterrupted: "Paused"
        case .audioPaused: "Listening paused"
        case .audioRecovering: "Restarting the microphone…"
        case .audioFailed: "Audio couldn't start"
        case .modelsWaitingForNetwork: "Waiting for a connection"
        case .modelsWaitingForWiFi: "Waiting for Wi-Fi"
        case .modelsStorageFull: "Not enough storage"
        case .modelDownloadFailed: "Download failed"
        case .modelDamaged: "Download damaged"
        case .modelLoadFailed: "Speech model won't load"
        case .iCloudFull: "iCloud storage is full"
        case .iCloudUnavailable: "iCloud sync is off"
        case .iCloudSyncPaused: "iCloud sync paused"
        case .transcriptNotSaved: "Couldn't save the conversation"
        case .storeUnavailable: "Conversations aren't being saved"
        }
    }

    public var message: String {
        switch self {
        case .offline:
            "Blau keeps listening and saving what you say. Grok answers when you're back online."
        case .reconnecting:
            "The connection dropped. What you say is saved and sent as soon as it's back."
        case .grokUnreachable:
            "Blau couldn't connect to xAI and keeps trying. What you say is saved and sent once it connects."
        case .secureConnectionFailed:
            "Blau couldn't verify xAI's server. Check the date and time, sign in to this network if it asks, "
                + "or turn off a VPN."
        case .rateLimited:
            "xAI is limiting requests from your key right now. Blau tries again shortly."
        case .xaiServerError:
            "xAI's servers returned an error. Blau keeps trying; what you say is saved."
        case .missingAPIKey:
            "Grok needs your xAI API key to answer. Blau keeps transcribing meanwhile."
        case .invalidAPIKey:
            "Your API key was rejected. It may have been revoked or mistyped. Enter it again or create a new "
                + "one at console.x.ai."
        case .apiKeyDisabled:
            "The key or its team is blocked or disabled. Enable it at console.x.ai or use another key."
        case .insufficientCredits:
            "Your xAI team has no credits left or hit its spending limit. Add credits at console.x.ai, then "
                + "try again."
        case .voiceNotPermitted:
            "This key isn't allowed to use the realtime voice API. Allow it at console.x.ai or use another key."
        case .keychainLocked:
            "Your xAI key is in the Keychain, which is unavailable until you unlock your iPhone."
        case .keychainFailure:
            "The Keychain couldn't read your xAI key. Enter it again."
        case .replyFailed:
            "Something went wrong with that reply. Say it again to retry."
        case .replyTimedOut:
            "Grok didn't respond in time. Say it again to retry."
        case .unexpectedResponse:
            "xAI sent something Blau didn't expect. Try again; if it keeps happening, update Blau."
        case .microphoneDenied:
            "Blau needs the microphone to hear you. Turn it on in Settings."
        case .microphoneUnavailable:
            "The microphone went away and there's no other one to use. Connect a headset or unplug the "
                + "accessory, then resume."
        case .microphoneBusy:
            "A call or another app is using the microphone. Resume when it's free."
        case .audioInterrupted:
            "A call or another app interrupted Blau. It resumes on its own, or tap Resume."
        case .audioPaused:
            "Audio stopped while Blau was in the background. Resume to keep going."
        case .audioRecovering:
            "Audio stopped flowing, so Blau is restarting it. Nothing you said is lost."
        case .audioFailed:
            "Blau couldn't start the microphone and speaker. Try again."
        case .modelsWaitingForNetwork:
            "The speech models download when you're back online."
        case .modelsWaitingForWiFi:
            "The speech models download over Wi-Fi. You can use cellular data instead."
        case .modelsStorageFull:
            "Free up space on your iPhone for the speech models, then try again."
        case .modelDownloadFailed:
            "The speech models couldn't be downloaded. Check your connection and try again."
        case .modelDamaged:
            "A downloaded file was damaged. Try again."
        case .modelLoadFailed:
            "A speech model couldn't be loaded on this iPhone. Download it again."
        case .iCloudFull:
            "New conversations are saved on this iPhone but won't sync until you free up iCloud storage "
                + "(Settings > your name > iCloud)."
        case .iCloudUnavailable:
            "Sign in to iCloud and turn it on for Blau to sync. Everything is saved on this iPhone."
        case .iCloudSyncPaused:
            "Sync resumes on its own. Everything is saved on this iPhone."
        case .transcriptNotSaved:
            "The latest lines couldn't be written. Make sure your iPhone has free storage."
        case .storeUnavailable:
            "Blau couldn't open its database, so new conversations aren't kept. Restart Blau; your existing "
                + "data is untouched."
        }
    }

    /// The default recovery actions, most useful first.
    public var actions: [RecoveryAction] {
        switch self {
        case .offline, .reconnecting, .audioRecovering, .modelsWaitingForNetwork, .iCloudSyncPaused,
            .transcriptNotSaved, .storeUnavailable, .replyFailed, .replyTimedOut:
            []
        case .grokUnreachable, .secureConnectionFailed, .rateLimited, .xaiServerError, .keychainLocked,
            .unexpectedResponse:
            [.retry]
        case .missingAPIKey, .keychainFailure:
            [.updateAPIKey]
        case .invalidAPIKey:
            [.updateAPIKey, .openXAIConsole]
        case .apiKeyDisabled, .voiceNotPermitted:
            [.openXAIConsole, .updateAPIKey]
        case .insufficientCredits:
            [.openXAIConsole, .retry]
        case .microphoneDenied, .iCloudFull, .iCloudUnavailable:
            [.openSettings]
        case .microphoneUnavailable, .microphoneBusy, .audioInterrupted, .audioPaused, .audioFailed:
            [.resumeAudio]
        case .modelsWaitingForWiFi:
            [.downloadOnCellular]
        case .modelsStorageFull, .modelDownloadFailed, .modelDamaged, .modelLoadFailed:
            [.retryDownload]
        }
    }

    /// The codes of `area`, in catalog order.
    public static func codes(in area: IssueArea) -> [IssueCode] {
        allCases.filter { $0.area == area }
    }
}
