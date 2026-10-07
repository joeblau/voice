import BlauTelemetry
import Foundation
import Testing

@testable import Blau

@Suite("App diagnostics")
@MainActor
struct AppDiagnosticsTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AppDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func refreshLoadsRecordsAndOverview() async throws {
        defer { cleanUp() }
        let store = FileDiagnosticsStore(directory: directory)
        try store.save(DiagnosticsSamples.metricPayload(periodEnd: .now))
        let diagnostics = AppDiagnostics(store: store)

        #expect(diagnostics.overview.isEmpty)
        await diagnostics.refresh()
        #expect(diagnostics.records.count == 1)
        #expect(diagnostics.overview.metricPayloadCount == 1)
        #expect(diagnostics.lastError == nil)
    }

    @Test func samplePayloadsAndDelete() async {
        defer { cleanUp() }
        let diagnostics = AppDiagnostics(store: FileDiagnosticsStore(directory: directory))
        await diagnostics.addSamplePayloads()
        #expect(diagnostics.overview.metricPayloadCount == 1)
        #expect(diagnostics.overview.diagnosticPayloadCount == 1)
        #expect(diagnostics.overview.hangReportCount == 1)

        await diagnostics.removeAll()
        #expect(diagnostics.overview.isEmpty)
        #expect(diagnostics.records.isEmpty)
    }

    @Test func exportFileWritesTheStoredPayloads() async throws {
        defer { cleanUp() }
        let diagnostics = AppDiagnostics(store: FileDiagnosticsStore(directory: directory))
        await diagnostics.addSamplePayloads()

        let file = try #require(diagnostics.exportFile)
        let url = try file.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.lastPathComponent.hasPrefix("Blau-Diagnostics-"))
        #expect(url.pathExtension == "json")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((document["payloads"] as? [Any])?.count == 2)
        let context = try #require(document["context"] as? [String: Any])
        #expect(context["bundleIdentifier"] as? String == Bundle.main.bundleIdentifier)
    }

    @Test func withoutStorageDiagnosticsAreOff() async {
        let diagnostics = AppDiagnostics(store: nil)
        diagnostics.start()
        await diagnostics.refresh()
        #expect(!diagnostics.isCollecting)
        #expect(diagnostics.exportFile == nil)
        #expect(diagnostics.overview.isEmpty)
    }

    @Test func exportContextDescribesTheApp() {
        let context = AppDiagnostics.exportContext()
        #expect(context.bundleIdentifier == "com.joeblau.blau")
        #expect(context.appVersion?.isEmpty == false)
        #expect(context.appBuild?.isEmpty == false)
        #expect(context.osVersion?.isEmpty == false)
        #expect(context.deviceModel?.isEmpty == false)
    }

    @Test func deviceModelPrefersTheSimulatedDevice() {
        #expect(AppDiagnostics.deviceModel(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,1"]) == "iPhone18,1")
        #expect(AppDiagnostics.deviceModel(environment: [:])?.isEmpty == false)
    }
}
