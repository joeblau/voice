import Foundation
import SwiftData

/// How the synced store is opened for this run of the app.
public enum SyncMode: Sendable, Hashable {
    /// Mirrored to the private database of the CloudKit container.
    case cloudKit(containerIdentifier: String)
    /// The same on-disk store with CloudKit mirroring off. Nothing is lost:
    /// changes made meanwhile are kept in the store's persistent history and
    /// exported the next time the store opens with CloudKit.
    case localOnly(LocalOnlyReason)
    /// A throwaway in-memory store (UI tests, previews, or the last resort
    /// when the on-disk store can't be opened at all).
    case inMemory(InMemoryReason)

    /// Why sync is off.
    public enum LocalOnlyReason: Sendable, Hashable {
        /// The iCloud account doesn't allow sync.
        case account(CloudAccountStatus)
        /// This build has no iCloud entitlement (an unsigned simulator or CI
        /// build).
        case notEntitled
        /// Forced by a launch argument or environment variable.
        case forced
        /// Opening the store with CloudKit failed; it was reopened without.
        case cloudKitFailed(String)
    }

    /// Why the store is in memory.
    public enum InMemoryReason: Sendable, Hashable {
        /// Requested by a launch argument, environment variable or test host.
        case requested
        /// The on-disk store couldn't be opened. Data created now is lost on
        /// quit; the file on disk is left untouched for recovery.
        case storeFailed(String)
    }

    /// Whether CloudKit mirroring is on.
    public var isCloudKit: Bool {
        if case .cloudKit = self { true } else { false }
    }

    /// Whether data is written to disk.
    public var isPersistent: Bool {
        if case .inMemory = self { false } else { true }
    }

    /// The `cloudKitDatabase` for the synced store's `ModelConfiguration`.
    var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        if case .cloudKit(let containerIdentifier) = self {
            .private(containerIdentifier)
        } else {
            .none
        }
    }
}

/// A developer override for how the store opens.
public enum StoreOverride: String, Sendable, Hashable, CaseIterable {
    /// Always open the on-disk store without CloudKit.
    case local
    /// Use a fresh in-memory store (UI tests).
    case memory
}

/// When to run `initializeCloudKitSchema()` before opening the store. Only
/// DEBUG builds should ever pass anything but `.never`. See docs/release.md.
public enum SchemaInitializationPolicy: String, Sendable, Hashable {
    /// Never (Release builds).
    case never
    /// Once per schema shape: whenever the Core Data model's version hashes
    /// differ from the last successful initialization on this device.
    case whenSchemaChanges
    /// On every launch with CloudKit available.
    case always
}

/// Everything the persistence layer needs to know about the running build.
public struct PersistenceOptions: Sendable, Equatable {
    /// Info.plist key, set from `$(CODE_SIGNING_ALLOWED)` in `project.yml`:
    /// `YES` when the app was signed with its entitlements.
    public static let cloudKitEnabledInfoKey = "BlauCloudKitEnabled"

    /// Launch argument (`-BlauStore local|memory`) and `UserDefaults` key.
    public static let storeOverrideArgument = "BlauStore"

    /// Environment variable equivalent of `-BlauStore`.
    public static let storeOverrideEnvironmentKey = "BLAU_STORE"

    /// Launch argument that forces `initializeCloudKitSchema()` this launch
    /// (DEBUG builds only honour it).
    public static let initializeSchemaArgument = "-BlauInitializeCloudKitSchema"

    /// The CloudKit container to mirror to.
    public var containerIdentifier: String
    /// Where the stores live.
    public var location: StoreLocation
    /// Whether the build carries the iCloud entitlement. When `false`, Blau
    /// never touches `CKContainer` (it would raise) and stays local-only.
    public var cloudKitEntitled: Bool
    /// A developer or test override, or `nil` to follow the iCloud account.
    public var storeOverride: StoreOverride?
    /// When to initialize the CloudKit development schema.
    public var schemaInitialization: SchemaInitializationPolicy
    /// How long launch waits for the iCloud account status before opening
    /// the store local-only (it switches to iCloud as soon as the status
    /// arrives).
    public var accountStatusTimeout: Duration

    public init(
        containerIdentifier: String = BlauCloud.containerIdentifier,
        location: StoreLocation,
        cloudKitEntitled: Bool,
        storeOverride: StoreOverride? = nil,
        schemaInitialization: SchemaInitializationPolicy = .never,
        accountStatusTimeout: Duration = .seconds(3)
    ) {
        self.containerIdentifier = containerIdentifier
        self.location = location
        self.cloudKitEntitled = cloudKitEntitled
        self.storeOverride = storeOverride
        self.schemaInitialization = schemaInitialization
        self.accountStatusTimeout = accountStatusTimeout
    }

    /// Reads the options from the running app.
    ///
    /// - Parameters:
    ///   - infoDictionary: The app's Info.plist; `BlauCloudKitEnabled` must
    ///     be `YES` for CloudKit to be used.
    ///   - arguments: Process arguments; `-BlauStore local|memory` overrides
    ///     the store and `-BlauInitializeCloudKitSchema` forces schema
    ///     initialization when `allowsSchemaInitialization` is set.
    ///   - environment: Process environment; `BLAU_STORE` works like
    ///     `-BlauStore`. A hosted XCTest run (`XCTestConfigurationFilePath`)
    ///     defaults to an in-memory store so tests never touch real data.
    ///   - allowsSchemaInitialization: `true` only in DEBUG builds.
    public static func resolve(
        infoDictionary: [String: Any],
        arguments: [String],
        environment: [String: String],
        location: StoreLocation = .applicationSupport,
        allowsSchemaInitialization: Bool
    ) -> PersistenceOptions {
        let entitled = isYes(infoDictionary[cloudKitEnabledInfoKey])

        var storeOverride: StoreOverride?
        if let index = arguments.firstIndex(of: "-" + storeOverrideArgument), index + 1 < arguments.count {
            storeOverride = StoreOverride(rawValue: arguments[index + 1].lowercased())
        }
        if storeOverride == nil, let value = environment[storeOverrideEnvironmentKey] {
            storeOverride = StoreOverride(rawValue: value.lowercased())
        }
        if storeOverride == nil, environment["XCTestConfigurationFilePath"] != nil {
            storeOverride = .memory
        }

        let schemaInitialization: SchemaInitializationPolicy
        if !allowsSchemaInitialization {
            schemaInitialization = .never
        } else if arguments.contains(initializeSchemaArgument) {
            schemaInitialization = .always
        } else {
            schemaInitialization = .whenSchemaChanges
        }

        return PersistenceOptions(
            location: location,
            cloudKitEntitled: entitled,
            storeOverride: storeOverride,
            schemaInitialization: schemaInitialization
        )
    }

    /// Whether launch needs to ask iCloud for the account status at all.
    public var needsAccountStatus: Bool {
        storeOverride == nil && cloudKitEntitled
    }

    /// The mode to open the store in, given the account status (`nil` when
    /// it wasn't asked for or isn't known yet).
    public func syncMode(for accountStatus: CloudAccountStatus?) -> SyncMode {
        switch storeOverride {
        case .memory: return .inMemory(.requested)
        case .local: return .localOnly(.forced)
        case nil: break
        }
        guard cloudKitEntitled else { return .localOnly(.notEntitled) }
        let status = accountStatus ?? .couldNotDetermine
        guard status.allowsSync else { return .localOnly(.account(status)) }
        return .cloudKit(containerIdentifier: containerIdentifier)
    }

    private static func isYes(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let string as String:
            ["yes", "true", "1"].contains(string.trimmingCharacters(in: .whitespaces).lowercased())
        case let number as NSNumber: number.boolValue
        default: false
        }
    }
}
