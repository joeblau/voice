import BlauTelemetry
import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

/// The app's MetricKit diagnostics: owns the on-device payload store and the
/// MetricKit subscriber, and feeds the Developer diagnostics screen.
///
/// Created and started once in `BlauApp.init`, then handed to views through
/// the environment. Payloads stay on this device (see docs/performance.md,
/// "MetricKit and diagnostics"); they leave it only when the user exports
/// them through the share sheet.
@MainActor
@Observable
final class AppDiagnostics {
    /// What the screen shows. Refreshed with `refresh()`.
    private(set) var records: [DiagnosticsRecord] = []
    private(set) var overview = DiagnosticsOverview()
    /// Whether the MetricKit subscriber is registered.
    private(set) var isCollecting = false
    /// The last storage failure, for the screen to show.
    private(set) var lastError: String?

    /// `nil` when the Application Support directory isn't available, which
    /// leaves the app working with diagnostics off.
    @ObservationIgnored let store: (any DiagnosticsStoring)?
    @ObservationIgnored private var subscriber: MetricKitSubscriber?

    init(store: (any DiagnosticsStoring)?) {
        self.store = store
    }

    /// Diagnostics backed by the default on-device directory.
    static func live() -> AppDiagnostics {
        do {
            return AppDiagnostics(store: FileDiagnosticsStore(directory: try FileDiagnosticsStore.defaultDirectory()))
        } catch {
            Log.ui.error("Diagnostics disabled, no storage directory: \(error, privacy: .public)")
            return AppDiagnostics(store: nil)
        }
    }

    /// Subscribes to MetricKit. Registration and the catch-up on payloads
    /// MetricKit delivered before this launch run off the main thread so
    /// they never delay the first frame.
    func start() {
        guard let store, subscriber == nil else { return }
        let subscriber = MetricKitSubscriber(store: store)
        self.subscriber = subscriber
        isCollecting = true
        Task.detached(priority: .utility) {
            subscriber.start()
        }
    }

    /// Reloads the stored records and the overview.
    func refresh() async {
        guard let store else { return }
        do {
            let records = try await Task.detached(priority: .userInitiated) { try store.records() }.value
            self.records = records
            overview = DiagnosticsOverview(records: records)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.ui.error("Couldn't load diagnostics: \(error, privacy: .public)")
        }
    }

    /// Deletes every stored payload.
    func removeAll() async {
        guard let store else { return }
        do {
            try await Task.detached(priority: .userInitiated) { try store.removeAll() }.value
        } catch {
            lastError = error.localizedDescription
            Log.ui.error("Couldn't delete diagnostics: \(error, privacy: .public)")
        }
        await refresh()
    }

    /// The file the share sheet exports. Built lazily, when the user picks a
    /// destination.
    var exportFile: DiagnosticsExportFile? {
        store.map { DiagnosticsExportFile(store: $0, context: Self.exportContext()) }
    }

    #if DEBUG
        /// Stores one made-up metric payload and one diagnostic payload, so
        /// the screen and the export can be tried in the Simulator, where
        /// MetricKit never delivers. Debug builds only.
        func addSamplePayloads() async {
            guard let store else { return }
            let now = Date.now
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.save(DiagnosticsSamples.metricPayload(periodEnd: now))
                    try store.save(DiagnosticsSamples.diagnosticPayload(periodEnd: now))
                }.value
            } catch {
                lastError = error.localizedDescription
            }
            await refresh()
        }
    #endif

    /// The app and device an export describes.
    nonisolated static func exportContext(
        bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo
    ) -> DiagnosticsExportContext {
        DiagnosticsExportContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: bundle.bundleIdentifier,
            osVersion: processInfo.operatingSystemVersionString,
            deviceModel: deviceModel(environment: processInfo.environment)
        )
    }

    /// The hardware identifier, e.g. `iPhone17,1`. In the Simulator that is
    /// the simulated device's identifier.
    nonisolated static func deviceModel(environment: [String: String]) -> String? {
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }
}

/// The diagnostics export as a share-sheet item: one JSON file with every
/// stored payload (see `DiagnosticsExport`).
struct DiagnosticsExportFile: Transferable, Sendable {
    let store: any DiagnosticsStoring
    let context: DiagnosticsExportContext

    /// Exports into a fresh folder under the temporary directory and returns
    /// the file. The system deletes temporary files on its own schedule.
    func write() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticsExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try store.export(context: context, to: folder)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try file.write())
        }
    }
}
