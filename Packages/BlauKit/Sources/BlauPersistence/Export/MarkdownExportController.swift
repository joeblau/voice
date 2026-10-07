import BlauCore
import BlauTelemetry
import Foundation
import Observation
import SwiftData
import Synchronization
import os

// MARK: - Preferences

/// Where the export settings are kept.
public protocol MarkdownExportPreferencesStore: Sendable {
    /// Whether conversations are exported automatically. Off by default.
    var isAutoExportEnabled: Bool { get nonmutating set }
    /// When an export last finished without errors.
    var lastExportedAt: Date? { get nonmutating set }
    /// An automatic export failed after reading which conversations changed,
    /// so the next one exports everything instead of losing those changes.
    var needsFullExport: Bool { get nonmutating set }
}

/// The export settings in `UserDefaults`.
public struct UserDefaultsMarkdownExportPreferences: MarkdownExportPreferencesStore {
    public static let autoExportKey = "blau.export.markdown.auto"
    public static let lastExportedAtKey = "blau.export.markdown.lastExportedAt"
    public static let needsFullExportKey = "blau.export.markdown.needsFullExport"

    private let suiteName: String?

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var isAutoExportEnabled: Bool {
        get { defaults.bool(forKey: Self.autoExportKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoExportKey) }
    }

    public var lastExportedAt: Date? {
        get { defaults.object(forKey: Self.lastExportedAtKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastExportedAtKey) }
    }

    public var needsFullExport: Bool {
        get { defaults.bool(forKey: Self.needsFullExportKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.needsFullExportKey) }
    }
}

/// Export settings in memory, for tests and previews.
public final class InMemoryMarkdownExportPreferences: MarkdownExportPreferencesStore {
    private struct Values {
        var isAutoExportEnabled: Bool
        var lastExportedAt: Date?
        var needsFullExport = false
    }

    private let values: Mutex<Values>

    public init(isAutoExportEnabled: Bool = false, lastExportedAt: Date? = nil) {
        values = Mutex(Values(isAutoExportEnabled: isAutoExportEnabled, lastExportedAt: lastExportedAt))
    }

    public var isAutoExportEnabled: Bool {
        get { values.withLock { $0.isAutoExportEnabled } }
        set { values.withLock { $0.isAutoExportEnabled = newValue } }
    }

    public var lastExportedAt: Date? {
        get { values.withLock { $0.lastExportedAt } }
        set { values.withLock { $0.lastExportedAt = newValue } }
    }

    public var needsFullExport: Bool {
        get { values.withLock { $0.needsFullExport } }
        set { values.withLock { $0.needsFullExport = newValue } }
    }
}

// MARK: - Controller

/// The Markdown export as Settings and the app see it (#78): "Export Now",
/// the "Export Automatically" toggle, and the result of the last export.
///
/// - **Manual** (`exportNow()`): every conversation, including one being
///   recorded.
/// - **Automatic** (when the toggle is on): `run()` follows the store's
///   changes (`PersistenceController.storeChanges()`), waits
///   `autoExportDelay` for them to settle, then exports the conversations
///   whose rows changed, read from SwiftData history with the controller's
///   own cursor (`historyConsumer`), so nothing is missed across launches.
///   Conversations still being recorded are skipped until they end, so a
///   two-hour session isn't re-uploaded every few seconds. Turning the
///   toggle on exports everything once. The app also calls
///   `flushAutoExport()` when it leaves the foreground.
///
/// Exports run one at a time, in order, on `MarkdownExporter`'s queue; the
/// controller only keeps state on the main actor. The exporter is rebuilt
/// when the persistence controller replaces its container (an iCloud
/// account change).
@MainActor
@Observable
public final class MarkdownExportController {
    /// What started an export.
    public enum Trigger: String, Sendable {
        case manual
        case automatic
    }

    /// The result of one finished export.
    public struct Outcome: Sendable, Equatable {
        public var trigger: Trigger
        public var finishedAt: Date
        public var result: Result<MarkdownExportReport, MarkdownExportError>

        public init(trigger: Trigger, finishedAt: Date, result: Result<MarkdownExportReport, MarkdownExportError>) {
            self.trigger = trigger
            self.finishedAt = finishedAt
            self.result = result
        }
    }

    /// The SwiftData history consumer name of the automatic export's cursor.
    public static let historyConsumer = "markdown-export"

    /// Whether an export is running.
    public private(set) var isExporting = false
    /// The last export that ran (an automatic pass that found nothing to do
    /// doesn't count).
    public private(set) var lastOutcome: Outcome?
    /// When an export last finished without errors, across launches.
    public private(set) var lastExportedAt: Date?

    /// The "Export Automatically" setting. Turning it on exports every
    /// conversation that has ended.
    public var isAutoExportEnabled: Bool {
        get { autoExportEnabled }
        set { setAutoExportEnabled(newValue) }
    }

    /// How long changes settle before an automatic export.
    public let autoExportDelay: Duration

    private var autoExportEnabled: Bool

    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let destination: MarkdownExportDestination
    @ObservationIgnored private let fileSystem: any MarkdownExportFileSystem
    @ObservationIgnored private let preferences: any MarkdownExportPreferencesStore
    @ObservationIgnored private let timeZone: @Sendable () -> TimeZone
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private var pipeline: Pipeline?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    /// Whether `run()` is following store changes (for tests).
    @ObservationIgnored private(set) var isFollowingChanges = false

    private struct Pipeline {
        let generation: Int
        let exporter: MarkdownExporter
        let tracker: PersistentHistoryTracker
    }

    private enum Job {
        case manual
        /// The toggle was turned on: skip history read so far, export all.
        case enable
        case automatic

        var trigger: Trigger {
            switch self {
            case .manual: .manual
            case .enable, .automatic: .automatic
            }
        }
    }

    /// - Parameters:
    ///   - persistence: Supplies the synced store (and its replacements).
    ///   - destination: Where files go: iCloud Drive in the app.
    ///   - fileSystem: Coordinated file access.
    ///   - preferences: Where the toggle and the last export date are kept.
    ///   - autoExportDelay: How long changes settle before an automatic
    ///     export.
    ///   - timeZone: The time zone for conversations exported the first
    ///     time.
    public init(
        persistence: PersistenceController,
        destination: MarkdownExportDestination,
        fileSystem: any MarkdownExportFileSystem = CoordinatedMarkdownFileSystem(),
        preferences: any MarkdownExportPreferencesStore = UserDefaultsMarkdownExportPreferences(),
        autoExportDelay: Duration = .seconds(5),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        clock: any BlauClock = SystemClock()
    ) {
        self.persistence = persistence
        self.destination = destination
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.autoExportDelay = autoExportDelay
        self.timeZone = timeZone
        self.clock = clock
        self.autoExportEnabled = preferences.isAutoExportEnabled
        self.lastExportedAt = preferences.lastExportedAt
    }

    // MARK: - Actions

    /// Exports every conversation now and waits for it to finish.
    public func exportNow() async {
        await enqueue(.manual)
    }

    /// Turns automatic export on or off. Turning it on starts a full export
    /// of the conversations that have ended.
    public func setAutoExportEnabled(_ enabled: Bool) {
        guard enabled != autoExportEnabled else { return }
        autoExportEnabled = enabled
        preferences.isAutoExportEnabled = enabled
        Log.data.notice("Automatic Markdown export \(enabled ? "on" : "off", privacy: .public)")
        scheduled?.cancel()
        scheduled = nil
        if enabled {
            start(.enable)
        }
    }

    /// Follows the store's changes and exports automatically while the
    /// toggle is on, until the calling task is cancelled.
    public func run() async {
        await persistence.start()
        let changes = persistence.storeChanges()
        if autoExportEnabled {
            // Catch up with whatever changed while Blau wasn't running.
            await enqueue(.automatic)
        }
        isFollowingChanges = true
        defer { isFollowingChanges = false }
        for await _ in changes where autoExportEnabled {
            scheduleAutoExport(after: autoExportDelay)
        }
        scheduled?.cancel()
    }

    /// Runs a scheduled automatic export now instead of after the delay.
    /// The app calls it when it leaves the foreground.
    public func flushAutoExport() async {
        guard autoExportEnabled else { return }
        scheduled?.cancel()
        scheduled = nil
        await enqueue(.automatic)
    }

    /// Waits for every export started so far to finish.
    public func waitUntilIdle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    /// Starts an automatic export after `delay`, replacing one already
    /// scheduled, so a burst of changes leads to one export.
    func scheduleAutoExport(after delay: Duration) {
        scheduled?.cancel()
        let clock = clock
        scheduled = Task {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self.enqueue(.automatic)
        }
    }

    // MARK: - Running exports

    /// Runs `job` after every job enqueued before it and waits for it.
    private func enqueue(_ job: Job) async {
        await start(job).value
    }

    /// Queues `job` behind every job queued before it. Synchronous, so the
    /// job is in the queue (and `waitUntilIdle()` sees it) on return.
    @discardableResult
    private func start(_ job: Job) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await self.perform(job)
        }
        tail = task
        return task
    }

    private func perform(_ job: Job) async {
        if case .automatic = job, !autoExportEnabled { return }
        isExporting = true
        defer { isExporting = false }

        guard let pipeline = await currentPipeline() else {
            finish(job.trigger, with: .failure(.storeUnavailable))
            return
        }
        switch job {
        case .manual:
            finish(.manual, with: await Self.result { try await pipeline.exporter.exportAll() })
        case .enable:
            // Everything up to now is covered by the full export, so move
            // the cursor first; changes made while it runs are read next time.
            _ = try? await pipeline.tracker.fetchNewChanges()
            finish(.automatic, with: await Self.result { try await pipeline.exporter.exportAll(includeOpen: false) })
        case .automatic:
            let changes: StoreChangeSet
            do {
                changes = try await pipeline.tracker.fetchNewChanges()
            } catch {
                Log.data.error("Export: reading history failed: \(String(describing: error), privacy: .public)")
                finish(.automatic, with: .failure(.storeUnavailable))
                return
            }
            if preferences.needsFullExport {
                finish(
                    .automatic, with: await Self.result { try await pipeline.exporter.exportAll(includeOpen: false) })
                return
            }
            guard !changes.isEmpty else { return }
            finish(.automatic, with: await Self.result { try await pipeline.exporter.export(affectedBy: changes) })
        }
    }

    private static func result(
        _ body: () async throws -> MarkdownExportReport
    ) async -> Result<MarkdownExportReport, MarkdownExportError> {
        do {
            return .success(try await body())
        } catch let error as MarkdownExportError {
            return .failure(error)
        } catch {
            // The exporter only throws `MarkdownExportError`.
            return .failure(.folderUnavailable(String(describing: error)))
        }
    }

    private func finish(_ trigger: Trigger, with result: Result<MarkdownExportReport, MarkdownExportError>) {
        let now = clock.now
        lastOutcome = Outcome(trigger: trigger, finishedAt: now, result: result)
        switch result {
        case .success(let report) where report.failures.isEmpty:
            lastExportedAt = now
            preferences.lastExportedAt = now
            // Every success that could have been owed one was a full export
            // (manual, enabling, or the automatic catch-up below).
            preferences.needsFullExport = false
        case .success, .failure:
            // What an automatic export read from history is gone; export
            // everything next time so those changes still reach the files.
            if trigger == .automatic {
                preferences.needsFullExport = true
            }
            if case .failure(let error) = result {
                Log.data.error("Markdown export failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The exporter and history tracker for the store that is open now.
    private func currentPipeline() async -> Pipeline? {
        await persistence.start()
        guard let stack = persistence.stack else { return nil }
        if let pipeline, pipeline.generation == persistence.generation {
            return pipeline
        }
        let pipeline = Pipeline(
            generation: persistence.generation,
            exporter: MarkdownExporter(
                source: SwiftDataConversationExportSource(modelContainer: stack.container),
                destination: destination,
                fileSystem: fileSystem,
                timeZone: timeZone,
                clock: clock
            ),
            tracker: PersistentHistoryTracker(
                consumer: Self.historyConsumer,
                container: stack.container,
                cursors: HistoryCursorStore(modelContainer: stack.derivedContainer),
                startPosition: .beginning,
                clock: clock
            )
        )
        self.pipeline = pipeline
        return pipeline
    }
}
