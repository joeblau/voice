import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import os

/// Accessibility identifiers for Settings → Privacy & Data, shared with UI
/// tests.
enum PrivacySettingsIdentifiers {
    static func delete(_ scope: DataEraseScope) -> String { "settings.privacy.delete.\(scope.rawValue)" }
    static let confirm = "settings.privacy.confirm"
    static let result = "settings.privacy.result"
    static let progress = "settings.privacy.progress"
    static let sentToXAI = "settings.privacy.xai"
    static let exportPrepare = "settings.privacy.export.prepare"
    static let exportShare = "settings.privacy.export.share"
    static let exportAgain = "settings.privacy.export.again"
}

/// Settings → Privacy & Data (#79): what Blau keeps and where, what it sends
/// to xAI, exporting all of it, and deleting it.
///
/// Deleting goes through `DataEraser`, record by record, so the deletions
/// sync to iCloud and the user's other devices. Nothing is deleted while a
/// conversation is recording: the pipeline is writing to the same store.
struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @State private var pending: DataEraseScope?
    @State private var pendingCount = 0
    /// The delete running now. It can wait for a memory update to finish
    /// first, so the pane says what it is doing.
    @State private var erasing: DataEraseScope?
    @State private var result: String?
    @State private var problem: String?
    /// The export lives here, not in its section, so a delete can withdraw
    /// it: the delete removes the zip the share button points at.
    @State private var exports = DataExportModel()

    var body: some View {
        Form {
            Section {
                Label(
                    "Your conversations, knowledge and voiceprint are stored on this iPhone and in your private iCloud.",
                    systemImage: "lock.icloud")
                Label(
                    "Speech is transcribed and matched to your voice on this iPhone. Your recordings never leave it.",
                    systemImage: "waveform.badge.mic")
                Label("Your xAI key stays in your iCloud Keychain. There is no Blau server.", systemImage: "key")
            } header: {
                Text("Where Your Data Lives")
            }
            .font(.subheadline)

            SentToXAISection()

            DataExportSection(model: exports, isErasing: erasing != nil)

            Section {
                ForEach(DataEraseScope.allCases, id: \.self) { scope in
                    Button(Self.buttonTitle(scope), role: .destructive) {
                        confirm(scope)
                    }
                    // An export still being written would hold what is about
                    // to be deleted, so the two never overlap.
                    .disabled(erasing != nil || exports.isPreparing)
                    .accessibilityIdentifier(PrivacySettingsIdentifiers.delete(scope))
                }
                if let erasing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(Self.progressMessage(erasing))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(PrivacySettingsIdentifiers.progress)
                }
                if let result {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(PrivacySettingsIdentifiers.result)
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Delete Data")
            } footer: {
                Text(
                    "Deleting removes the data from this iPhone, from iCloud and from your other devices. "
                        + "It can't be undone. Files you exported or shared, including the Markdown copies in "
                        + "iCloud Drive → Blau, aren't affected."
                )
            }
        }
        .navigationTitle("Privacy & Data")
        // A delete can wait minutes for a memory update; Settings stays up
        // until it finishes. (It re-checks for a conversation right before
        // deleting either way.)
        .interactiveDismissDisabled(erasing != nil)
        .confirmationDialog(
            pending.map(Self.confirmationTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { scope in
            Button(Self.buttonTitle(scope).replacingOccurrences(of: "…", with: ""), role: .destructive) {
                // Set now, not in the task, so Export and the other deletes
                // are off from the confirming tap on.
                erasing = scope
                Task { await erase(scope) }
            }
            .accessibilityIdentifier(PrivacySettingsIdentifiers.confirm)
        } message: { scope in
            let keepsMarkdownCopies = Self.hasMarkdownCopies(environment.markdownExport)
            Text(Self.confirmationMessage(scope, count: pendingCount, keepsMarkdownCopies: keepsMarkdownCopies))
        }
    }

    private func confirm(_ scope: DataEraseScope) {
        result = nil
        problem = nil
        pendingCount = (try? DataEraser.count(scope, in: modelContext)) ?? 0
        pending = scope
    }

    private func erase(_ scope: DataEraseScope) async {
        erasing = scope
        defer { erasing = nil }
        do {
            let summary = try await PrivacyDataEraser.erase(
                scope, in: modelContext, profileMemory: environment.profileMemory, exports: exports,
                conversation: .live(environment))
            result = Self.resultMessage(scope, summary: summary)
        } catch PrivacyDataEraser.Refusal.conversationRunning {
            problem = String(localized: "Stop the conversation first, then delete.")
        } catch {
            problem = String(localized: "Couldn't delete the data. Nothing was changed. Try again.")
        }
    }

    // MARK: Wording

    static func buttonTitle(_ scope: DataEraseScope) -> String {
        switch scope {
        case .conversations: String(localized: "Delete All Conversations…")
        case .learnedFacts: String(localized: "Delete Learned Facts…")
        case .knowledge: String(localized: "Delete Knowledge Base…")
        case .voiceprint: String(localized: "Delete Voiceprint…")
        case .everything: String(localized: "Delete All Data…")
        }
    }

    static func confirmationTitle(_ scope: DataEraseScope) -> String {
        switch scope {
        case .conversations: String(localized: "Delete all conversations?")
        case .learnedFacts: String(localized: "Delete what Blau learned?")
        case .knowledge: String(localized: "Delete the knowledge base?")
        case .voiceprint: String(localized: "Delete your voiceprint?")
        case .everything: String(localized: "Delete all your data?")
        }
    }

    /// - Parameter keepsMarkdownCopies: Conversations were exported to
    ///   iCloud Drive → Blau (#78); those files are the user's and stay.
    static func confirmationMessage(_ scope: DataEraseScope, count: Int, keepsMarkdownCopies: Bool = false)
        -> String
    {
        let what: String =
            switch scope {
            case .conversations:
                count == 1 ? String(localized: "1 conversation") : String(localized: "\(count) conversations")
            case .learnedFacts:
                count == 1
                    ? String(localized: "1 learned fact and the profile summary built from it")
                    : String(localized: "\(count) learned facts and the profile summary built from them")
            case .knowledge: String(localized: "\(count) items in your knowledge base")
            case .voiceprint: String(localized: "your voiceprint")
            case .everything: String(localized: "every conversation, your knowledge base and your voiceprint")
            }
        var message = String(localized: "This deletes \(what) from this iPhone, iCloud and your other devices.")
        if scope == .learnedFacts {
            message += " " + String(localized: "Your About Me, company, notes and collections stay.")
        }
        if scope == .voiceprint || scope == .everything {
            message += " " + String(localized: "You'll need to enroll again for Voice ID.")
        }
        if keepsMarkdownCopies, scope.components.contains(.conversations) {
            message +=
                " "
                + String(
                    localized: "The Markdown copies in iCloud Drive → Blau aren't deleted; remove them in Files.")
        }
        return message
    }

    /// Whether Markdown copies of the conversations may be in iCloud Drive
    /// → Blau: an export ran, or runs automatically.
    static func hasMarkdownCopies(_ export: MarkdownExportController) -> Bool {
        export.isAutoExportEnabled || export.lastExportedAt != nil
    }

    /// What the pane shows while a delete runs. Deleting what Blau learned
    /// first lets a memory update already talking to xAI finish.
    static func progressMessage(_ scope: DataEraseScope) -> String {
        scope.erasesLearnedFacts
            ? String(localized: "Finishing Blau's memory update, then deleting…")
            : String(localized: "Deleting…")
    }

    static func resultMessage(_ scope: DataEraseScope, summary: DataEraseSummary) -> String {
        switch scope {
        case .conversations:
            summary.conversations == 1
                ? String(localized: "Deleted 1 conversation.")
                : String(localized: "Deleted \(summary.conversations) conversations.")
        case .learnedFacts:
            summary.facts == 1
                ? String(localized: "Deleted 1 learned fact.")
                : String(localized: "Deleted \(summary.facts) learned facts.")
        case .knowledge: String(localized: "Deleted the knowledge base.")
        case .voiceprint: String(localized: "Deleted your voiceprint.")
        case .everything: String(localized: "Deleted all your data.")
        }
    }
}

// MARK: - Deleting

/// What Delete does beyond `DataEraser` (which deletes the synced records):
/// the per-device copies of the same data go too.
@MainActor
enum PrivacyDataEraser {
    enum Refusal: Error, Equatable {
        /// The pipeline is writing to the same store.
        case conversationRunning
    }

    /// Whether a conversation is on. `erase` asks before it starts and
    /// again right before it deletes: waiting for a memory update can take
    /// minutes, and a conversation can start meanwhile.
    @MainActor
    struct ConversationCheck {
        /// Main-actor state a conversation sets as it starts, before it
        /// writes to the store (`VoiceLoop.phase`, the record button's
        /// session). Read with no `await` between it and the delete, so
        /// nothing can start in between.
        var isActive: @MainActor () -> Bool
        /// State that takes an `await` to read: the microphone, which an
        /// actor owns.
        var isCapturing: @MainActor () async -> Bool = { false }

        /// No conversation runs (tests).
        static let idle = ConversationCheck(isActive: { false })

        /// The app's conversation: the voice loop, the record button's
        /// session and the microphone.
        static func live(_ environment: AppEnvironment) -> ConversationCheck {
            ConversationCheck(
                isActive: { environment.voiceLoop.phase.isActive || environment.conversation.status.isRunning },
                isCapturing: { await environment.audio.isCapturing })
        }

        /// Both, the awaited half first, so `isActive` is the last thing
        /// read before the caller (on the main actor too) carries on.
        func isRunning() async -> Bool {
            let capturing = await isCapturing()
            return capturing || isActive()
        }
    }

    /// Deletes `scope` everywhere (`DataEraser`), then this device's copies:
    /// the share sheet's exports (withdrawn from `exports`, when the pane
    /// has one, so Share Export no longer offers the removed zip), and for
    /// the learned facts and the knowledge base the consolidation log, its
    /// notes and the pinned memory cache. For the conversations alone, the
    /// topic titles and summaries in the consolidation log go
    /// (`ProfileMemory.conversationsErased()`); what was learned stays.
    ///
    /// Before the learned facts go, fact extraction is suspended (the
    /// request in flight is cancelled) and a consolidation already running
    /// finishes, so neither writes facts or a profile from what was read
    /// before the delete (`ProfileMemory.prepareToErase()`). Before the
    /// conversations alone go, a running consolidation finishes too, so the
    /// topic summaries it logs are there to remove.
    ///
    /// Nothing is deleted while a conversation runs (`Refusal`): checked
    /// first, and again after that wait, right before the delete, since one
    /// can start while it lasts.
    @discardableResult
    static func erase(
        _ scope: DataEraseScope, in context: ModelContext, profileMemory: ProfileMemory, exports: DataExportModel?,
        conversation: ConversationCheck
    ) async throws -> DataEraseSummary {
        guard !(await conversation.isRunning()) else { throw Refusal.conversationRunning }
        if scope.erasesLearnedFacts {
            await profileMemory.prepareToErase()
        } else if scope.components.contains(.conversations) {
            await profileMemory.prepareToEraseConversations()
        }
        // A conversation may have started during the wait. `isRunning()`
        // reads `isActive` last, on the main actor, and nothing is awaited
        // between it and `DataEraser.erase`, so none can start in between.
        guard !(await conversation.isRunning()) else {
            if scope.erasesLearnedFacts {
                // Nothing was deleted: extraction carries on where it was.
                await profileMemory.eraseFailed()
            }
            throw Refusal.conversationRunning
        }
        let summary: DataEraseSummary
        do {
            summary = try DataEraser.erase(scope, in: context)
        } catch {
            if scope.erasesLearnedFacts {
                // Nothing was deleted: extraction carries on where it was.
                await profileMemory.eraseFailed()
            }
            throw error
        }
        // The share sheet's copies hold what was just deleted; they go with
        // it.
        DataExportFiles.removeAll()
        exports?.dataErased()
        if scope.components.contains(.conversations) {
            ConversationExportFiles.removeAll()
        }
        if scope.erasesLearnedFacts {
            // Covers the topic summaries in the log too: every record goes.
            await profileMemory.memoryErased()
        } else if scope.components.contains(.conversations) {
            await profileMemory.conversationsErased()
        }
        return summary
    }
}

// MARK: - What is sent to xAI

/// What leaves the device for xAI, and what comes back (#79). Blau has no
/// server: these requests go straight from the iPhone to xAI with the
/// user's own key (#33).
struct SentToXAISection: View {
    /// One kind of data that goes to xAI, or comes back.
    struct Item: Hashable {
        var title: String
        var detail: String
        var systemImage: String
    }

    /// Everything Blau sends, in the order a conversation sends it. Kept in
    /// step with docs/privacy.md.
    static var items: [Item] {
        [
            Item(
                title: String(localized: "What you say, as text"),
                detail: String(
                    localized:
                        "Only speech Voice ID matched to you, after it is transcribed on this iPhone. Your audio is never sent."
                ),
                systemImage: "text.bubble"),
            Item(
                title: String(localized: "What Grok needs to answer"),
                detail: String(
                    localized:
                        "Your About Me page, your profile summary and current facts at the start of each conversation, and the results of the memory searches Grok asks for."
                ),
                systemImage: "brain"),
            Item(
                title: String(localized: "What Blau learns from"),
                detail: String(
                    localized:
                        "With Learn From Conversations on, each finished topic's transcript, to pick out facts and update your profile summary."
                ),
                systemImage: "lightbulb"),
            Item(
                title: String(localized: "What comes back"),
                detail: String(
                    localized:
                        "Grok's reply as audio and its transcript. Web and X searches, when they are on, run at xAI."),
                systemImage: "speaker.wave.2"),
        ]
    }

    var body: some View {
        Section {
            ForEach(Self.items, id: \.self) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.systemImage)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("What's Sent to xAI")
        } footer: {
            Text(
                "These go straight from this iPhone to xAI under your own xAI account; no one else, Blau included, "
                    + "sees them on the way. Your voiceprint and recordings never leave your devices and iCloud."
            )
        }
        .accessibilityIdentifier(PrivacySettingsIdentifiers.sentToXAI)
    }
}

// MARK: - Export everything

/// The share sheet's copy of everything: one zip in the app's temporary
/// directory. It holds all the user's data, so it never outlives what it
/// copies for long: each export replaces the last, every delete in
/// Privacy & Data removes it (`removeAll()`), leaving Privacy & Data
/// removes the one it offered (`DataExportModel`'s deinit), and launch
/// removes any an earlier run left (`AppEnvironment.start()`).
enum DataExportFiles {
    static var directory: URL {
        URL.temporaryDirectory.appending(path: "DataExport", directoryHint: .isDirectory)
    }

    /// Writes `export` as a zip in a folder of its own, replacing earlier
    /// exports. The zip keeps its readable name for the share sheet; the
    /// folder lets `remove(_:)` take exactly this export. Runs off the main
    /// actor: a long history takes a while to format and compress.
    static func write(_ export: DataExport) throws -> URL {
        removeAll()
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try DataExporter().writeArchive(export, in: folder)
    }

    /// Removes one export `write(_:)` made, with its folder; a later export
    /// stays.
    static func remove(_ archive: URL) {
        let folder = archive.deletingLastPathComponent()
        let isOwnFolder =
            folder.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            == directory.standardizedFileURL.path(percentEncoded: false)
        removeItem(at: isOwnFolder ? folder : archive)
    }

    /// Removes every exported file.
    static func removeAll() {
        removeItem(at: directory)
    }

    private static func removeItem(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was exported, or a delete already removed it.
        } catch {
            Log.ui.error("Couldn't remove the data export: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The state of Export All Data, owned by `PrivacySettingsView` so a delete
/// can withdraw the export it just removed (`dataErased()`).
@MainActor
@Observable
final class DataExportModel {
    struct Export: Equatable {
        var url: URL
        var counts: DataExport.Counts
    }

    /// Writes the zip and returns where it is and what it holds.
    typealias Writer = @Sendable () async throws -> (URL, DataExport.Counts)

    /// The export the share button offers.
    private(set) var export: Export?
    private(set) var isPreparing = false
    private(set) var failed = false
    /// Bumped by every delete. An export that started before a delete holds
    /// deleted data, so it is thrown away when it finishes.
    private(set) var erasures = 0

    /// Leaving Privacy & Data drops this model, and nothing can offer its
    /// export again: the zip goes now, not at the next export or launch.
    isolated deinit {
        if let export {
            DataExportFiles.remove(export.url)
        }
    }

    /// Prepares an export with `write`, replacing the last one.
    func prepare(_ write: Writer) async {
        guard !isPreparing else { return }
        isPreparing = true
        failed = false
        defer { isPreparing = false }
        let started = erasures
        do {
            let (url, counts) = try await write()
            guard erasures == started else {
                // Data was deleted while this was being written: the zip
                // holds it, so it goes too.
                DataExportFiles.remove(url)
                return
            }
            export = Export(url: url, counts: counts)
        } catch {
            Log.ui.error("Data export failed: \(String(describing: error), privacy: .public)")
            guard erasures == started else { return }
            export = nil
            failed = true
        }
    }

    /// The data the export copied was deleted, and with it the export's
    /// files (`DataExportFiles.removeAll()`): nothing is left to share.
    func dataErased() {
        erasures += 1
        export = nil
        failed = false
    }

    /// Reads the store on a context of its own and writes the zip off the
    /// main actor, so a long history doesn't freeze Settings.
    static func writer(for container: ModelContainer, app: String) -> Writer {
        {
            try await Task.detached(priority: .userInitiated) {
                let snapshot = try DataExport.snapshot(in: ModelContext(container), exportedAt: Date(), app: app)
                return (try DataExportFiles.write(snapshot), snapshot.counts)
            }.value
        }
    }
}

/// Export All Data: every record as JSON, plus the conversations and the
/// knowledge base as Markdown, zipped and offered through the share sheet
/// (`DataExport`, `DataExporter`). Its state is `DataExportModel`.
struct DataExportSection: View {
    @Environment(\.modelContext) private var modelContext
    let model: DataExportModel
    /// A delete is running; an export started now would copy what it is
    /// deleting.
    let isErasing: Bool

    var body: some View {
        Section {
            if let export = model.export {
                ShareLink(
                    item: export.url,
                    preview: SharePreview(export.url.lastPathComponent, image: Image(systemName: "doc.zipper"))
                ) {
                    Label("Share Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(PrivacySettingsIdentifiers.exportShare)
                Text(Self.summary(export.counts))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                let write = DataExportModel.writer(for: modelContext.container, app: SettingsSummary.version())
                Task { await model.prepare(write) }
            } label: {
                HStack {
                    Label(
                        model.export == nil ? "Export All Data" : "Export Again",
                        systemImage: model.export == nil ? "square.and.arrow.down.on.square" : "arrow.clockwise")
                    Spacer()
                    if model.isPreparing {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isPreparing || isErasing)
            .accessibilityIdentifier(
                model.export == nil
                    ? PrivacySettingsIdentifiers.exportPrepare : PrivacySettingsIdentifiers.exportAgain)
            if model.failed {
                Text("Couldn't export your data. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text(
                "A zip of everything Blau keeps: every record as JSON, and your conversations and knowledge base as "
                    + "Markdown. Your voiceprint is described, without the voice data itself."
            )
        }
    }

    /// "3 conversations, 5 pages and 12 learned facts".
    static func summary(_ counts: DataExport.Counts) -> String {
        let conversations =
            counts.conversations == 1
            ? String(localized: "1 conversation") : String(localized: "\(counts.conversations) conversations")
        let pages = counts.documents == 1 ? String(localized: "1 page") : String(localized: "\(counts.documents) pages")
        let facts =
            counts.facts == 1 ? String(localized: "1 learned fact") : String(localized: "\(counts.facts) learned facts")
        return String(localized: "\(conversations), \(pages) and \(facts)")
    }
}

#if DEBUG
    #Preview("Privacy") {
        NavigationStack {
            PrivacySettingsView()
        }
        .appEnvironment(.preview())
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
