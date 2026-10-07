import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTranscription
import Foundation
import Observation

/// What the main screen's issue banner shows (#80): the current issue of the
/// conversation (offline, reconnecting, a key or reply problem), the
/// conversation's audio (the microphone taken or gone) and iCloud (full),
/// worst first, through BlauCore's `IssueBoard`, plus the recovery actions
/// that don't need a view: Try Again, Discard, Resume.
///
/// `start()` follows the live sources: the turn orchestrator's snapshots,
/// the `AudioSessionKeeper`'s status and the store's `SyncState`. It also
/// feeds the orchestrator the network path (`NWPathMonitor`), which drives
/// the offline state and the reconnect when the network comes back.
@MainActor
@Observable
final class IssueCenter {
    /// UI tests show one catalog entry with `-BlauIssueFixture <code>`
    /// (e.g. `connection.offline`), on fake services.
    static let fixtureArgument = "BlauIssueFixture"

    private(set) var board = IssueBoard()

    /// The issues to show, worst first.
    var visible: [UserFacingIssue] { board.visible }

    /// The issue the banner shows.
    var primary: UserFacingIssue? { board.primary }

    @ObservationIgnored private let realtime: any RealtimeService
    @ObservationIgnored private let keeper: AudioSessionKeeper?
    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let network: (any NetworkMonitor)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isStarted = false

    /// - Parameters:
    ///   - realtime: The turn orchestrator, when it is the live one.
    ///   - keeper: The conversation audio's keeper (live app only).
    ///   - persistence: The store, for the iCloud sync state.
    ///   - network: The network path, fed to the orchestrator (live app
    ///     only).
    init(
        realtime: any RealtimeService,
        keeper: AudioSessionKeeper?,
        persistence: PersistenceController,
        network: (any NetworkMonitor)?
    ) {
        self.realtime = realtime
        self.keeper = keeper
        self.persistence = persistence
        self.network = network
    }

    isolated deinit {
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: Sources

    /// Starts following the sources. Runs once.
    func start(fixture: IssueCode? = nil) {
        guard !isStarted else { return }
        isStarted = true
        if let fixture {
            update(.conversation, Self.fixtureIssue(fixture))
        }
        if let orchestrator = realtime as? TurnOrchestrator {
            tasks.append(
                Task { [weak self] in
                    for await snapshot in orchestrator.updates() {
                        self?.update(.conversation, snapshot.issue)
                    }
                })
            if let network {
                let reachability = Self.reachability(of: network)
                tasks.append(Task { await orchestrator.follow(network: reachability) })
            }
        }
        if let keeper {
            tasks.append(
                Task { [weak self] in
                    for await snapshot in await keeper.updates() {
                        self?.update(.audio, snapshot.status.issue)
                    }
                })
        }
        let persistence = persistence
        tasks.append(
            Task { [weak self] in
                for await state in Observations({ persistence.syncState }) {
                    self?.update(.storage, state.issue)
                }
            })
    }

    /// Sets `source`'s issue, logging changes.
    func update(_ source: IssueBoard.Source, _ issue: UserFacingIssue?) {
        let previous = board.issue(from: source)
        guard previous != issue else { return }
        if previous?.code != issue?.code {
            if let issue {
                Log.ui.notice(
                    "Issue \(issue.code.rawValue, privacy: .public) (\(issue.severity.description, privacy: .public)) from \(source.rawValue, privacy: .public)"
                )
            } else {
                Log.ui.notice("Issue from \(source.rawValue, privacy: .public) resolved")
            }
        }
        board.update(source, issue)
    }

    /// Hides `issue` until it changes (see `IssueBoard`).
    func dismiss(_ issue: UserFacingIssue) {
        board.dismiss(issue.code)
    }

    // MARK: Actions

    /// Carries out the actions that need no view: reconnecting, discarding
    /// what waits, taking the audio back, the speech model downloads. The
    /// banner handles the rest (sheets and URLs, see `IssueBanner`).
    func perform(_ action: RecoveryAction, models: ModelManager) async {
        Log.ui.notice("Issue action \(action.rawValue, privacy: .public)")
        switch action {
        case .retry:
            // Only reconnects a running conversation: connecting with none
            // would start one without the microphone.
            guard let orchestrator = realtime as? TurnOrchestrator,
                await orchestrator.snapshot.conversationID != nil
            else { return }
            do {
                try await orchestrator.connect()
            } catch {
                Log.ui.error("Try Again didn't connect: \(String(describing: error), privacy: .public)")
            }
        case .discardQueued:
            await (realtime as? TurnOrchestrator)?.discardQueued()
        case .resumeAudio:
            do {
                try await keeper?.startCapture()
            } catch {
                Log.ui.error("Resume didn't restart the audio: \(String(describing: error), privacy: .public)")
            }
        case .retryDownload:
            for descriptor in models.manifest.required where !models.state(of: descriptor.id).isInstalled {
                await models.download(descriptor.id)
            }
        case .downloadOnCellular:
            models.allowExpensiveNetworkThisSession()
        case .updateAPIKey, .openXAIConsole, .openSettings:
            // Presented by the view.
            break
        }
    }

    // MARK: Helpers

    /// `network`'s reachability, as booleans.
    nonisolated static func reachability(of network: any NetworkMonitor) -> AsyncStream<Bool> {
        let statuses = network.updates()
        return AsyncStream { continuation in
            let task = Task {
                for await status in statuses {
                    continuation.yield(status.isReachable)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What a UI test fixture shows: the catalog entry, with a count of
    /// waiting messages for the connection issues so Discard appears.
    static func fixtureIssue(_ code: IssueCode) -> UserFacingIssue {
        let issue = UserFacingIssue(code)
        guard code.area == .connection else { return issue }
        return issue.withMessage(issue.message + " 2 messages are waiting to send.").adding(.discardQueued)
    }

    /// The fixture code in the launch arguments, if any.
    static func fixtureCode(in defaults: UserDefaults = .standard) -> IssueCode? {
        defaults.string(forKey: fixtureArgument).flatMap(IssueCode.init(rawValue:))
    }
}
