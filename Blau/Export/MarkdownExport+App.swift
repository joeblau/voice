import BlauPersistence
import Foundation

extension MarkdownExportController {
    /// The app's export (#78): into iCloud Drive → Blau when the build is
    /// signed with the iCloud entitlements, with the settings in
    /// `UserDefaults`. DEBUG UI-test runs keep the settings in the
    /// `blau.uitests` suite so they never change the developer's own choice.
    static func live(persistence: PersistenceController) -> MarkdownExportController {
        var preferences = UserDefaultsMarkdownExportPreferences()
        #if DEBUG
            if XAIUITestStub.current != nil {
                preferences = UserDefaultsMarkdownExportPreferences(suiteName: "blau.uitests")
            }
        #endif
        return MarkdownExportController(
            persistence: persistence,
            destination: .iCloudDrive(isEntitled: persistence.options.cloudKitEntitled),
            preferences: preferences
        )
    }

    /// An export into a fresh temporary folder with in-memory settings, for
    /// previews and tests: it never touches iCloud Drive or the user's
    /// settings.
    static func local(persistence: PersistenceController) -> MarkdownExportController {
        let folder = URL.temporaryDirectory.appending(
            path: "BlauExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        return MarkdownExportController(
            persistence: persistence,
            destination: .directory(folder),
            preferences: InMemoryMarkdownExportPreferences()
        )
    }
}
