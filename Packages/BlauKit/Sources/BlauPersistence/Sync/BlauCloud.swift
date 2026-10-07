import Foundation
import os

/// Constants for Blau's iCloud container and on-disk stores.
public enum BlauCloud {
    /// The CloudKit container every synced model is mirrored to. Must match
    /// `com.apple.developer.icloud-container-identifiers` in `project.yml`.
    public static let containerIdentifier = "iCloud.com.joeblau.blau"

    /// `ModelConfiguration` name of the synced store (text and voiceprint).
    public static let syncedConfigurationName = "Blau"

    /// `ModelConfiguration` name of the local-only store for derived data.
    public static let derivedConfigurationName = "BlauDerived"
}

/// The `data` logging category (`BlauTelemetry.LogCategory.data` once #17
/// lands) in Blau's unified-logging subsystem.
enum PersistenceLog {
    static let logger = Logger(subsystem: "com.joeblau.blau", category: "data")
}

/// Where the stores live on disk.
///
/// Both stores share one directory so a "delete all data" action (#79) has a
/// single place to clear. The synced store is the same file whether or not
/// CloudKit mirroring is on, so switching between iCloud sync and local-only
/// never splits or loses data. Derived data sits in a subdirectory that is
/// excluded from device backups: it is rebuilt from the synced store.
public struct StoreLocation: Sendable, Equatable {
    /// The directory holding every store.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Blau`, the production location.
    public static var applicationSupport: StoreLocation {
        StoreLocation(directory: URL.applicationSupportDirectory.appending(path: "Blau", directoryHint: .isDirectory))
    }

    /// The SQLite file of the synced (text and voiceprint) store.
    public var syncedStoreURL: URL {
        directory.appending(path: "Blau.store", directoryHint: .notDirectory)
    }

    /// The directory holding the derived, local-only store.
    public var derivedDirectory: URL {
        directory.appending(path: "Derived", directoryHint: .isDirectory)
    }

    /// The SQLite file of the derived, local-only store.
    public var derivedStoreURL: URL {
        derivedDirectory.appending(path: "BlauDerived.store", directoryHint: .notDirectory)
    }

    /// Creates the directories if needed and excludes the derived directory
    /// from backups.
    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: derivedDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var derived = derivedDirectory
        try derived.setResourceValues(values)
    }

    /// The SQLite file at `storeURL` and its `-wal` and `-shm` companions.
    static func sqliteFiles(for storeURL: URL) -> [URL] {
        let path = storeURL.path(percentEncoded: false)
        return [storeURL, URL(filePath: path + "-wal"), URL(filePath: path + "-shm")]
    }
}
