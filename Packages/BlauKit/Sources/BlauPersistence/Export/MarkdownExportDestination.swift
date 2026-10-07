import Foundation

/// Why an export couldn't run at all. Problems with a single conversation
/// don't stop an export; they are listed in `MarkdownExportReport.failures`.
public enum MarkdownExportError: Error, Sendable, Equatable {
    /// iCloud Drive can't be reached: the user isn't signed in to iCloud,
    /// iCloud Drive is off (for everything, or for Blau), or the container
    /// isn't set up yet.
    case iCloudDriveUnavailable
    /// This build isn't signed with the iCloud entitlements (unsigned
    /// simulator and CI builds).
    case notAvailableInThisBuild
    /// The stores aren't open.
    case storeUnavailable
    /// The export folder couldn't be created or listed.
    case folderUnavailable(String)
}

/// Where the Markdown files go.
///
/// The app uses `iCloudDrive()`: the `Documents` folder of Blau's ubiquity
/// container, which Files shows as iCloud Drive → Blau
/// (`NSUbiquitousContainers` in `project.yml`, see docs/export.md). Tests
/// and previews use `directory(_:)`.
public struct MarkdownExportDestination: Sendable {
    private let resolveDirectory: @Sendable () throws -> URL

    /// - Parameter resolve: Returns the folder to export into. Called on the
    ///   export queue, never the main thread.
    public init(resolve: @escaping @Sendable () throws -> URL) {
        self.resolveDirectory = resolve
    }

    /// The folder to export into.
    public func directory() throws(MarkdownExportError) -> URL {
        do {
            return try resolveDirectory()
        } catch let error as MarkdownExportError {
            throw error
        } catch {
            throw .folderUnavailable(String(describing: error))
        }
    }

    /// A fixed local folder.
    public static func directory(_ url: URL) -> MarkdownExportDestination {
        MarkdownExportDestination { url }
    }

    /// Always fails with `error`.
    public static func unavailable(_ error: MarkdownExportError) -> MarkdownExportDestination {
        MarkdownExportDestination { throw error }
    }

    /// The `Documents` folder of the iCloud container `containerIdentifier`.
    ///
    /// `FileManager.url(forUbiquityContainerIdentifier:)` returns `nil` when
    /// iCloud Drive is off or the user is signed out, and the first call can
    /// take a while (it sets up the container), which is why Apple says to
    /// call it off the main thread; the exporter only calls it on its queue.
    ///
    /// - Parameter isEntitled: `false` in a build without the iCloud
    ///   entitlements, which then never asks for the container.
    public static func iCloudDrive(
        containerIdentifier: String = BlauCloud.containerIdentifier,
        isEntitled: Bool
    ) -> MarkdownExportDestination {
        guard isEntitled else { return .unavailable(.notAvailableInThisBuild) }
        return MarkdownExportDestination {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
                throw MarkdownExportError.iCloudDriveUnavailable
            }
            // Only `Documents` is shown in iCloud Drive.
            return container.appending(path: "Documents", directoryHint: .isDirectory)
        }
    }
}
