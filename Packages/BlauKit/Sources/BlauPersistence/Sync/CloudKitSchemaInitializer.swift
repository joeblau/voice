import CoreData
import CryptoKit
import Foundation
import SwiftData

/// Creates the CloudKit **development** schema from the SwiftData model.
///
/// SwiftData creates record types lazily, as records are first exported, so a
/// type or field that has never been written (an optional field, a model
/// nobody has created yet) is missing from the development schema and then
/// from production. `initializeCloudKitSchema()` uploads a representative
/// record of every type, so the whole schema exists before it is deployed to
/// production (docs/release.md).
///
/// SwiftData has no API for this, so the initializer opens the same store
/// file with an `NSPersistentCloudKitContainer` built from the Core Data
/// model SwiftData generates, initializes the schema, and closes the store
/// again before SwiftData opens it. This is Apple's documented approach
/// ("Syncing model data across a person's devices"). It talks to CloudKit
/// and takes a few seconds, so DEBUG builds only run it when the model
/// changes (`SchemaInitializationPolicy.whenSchemaChanges`).
public protocol CloudKitSchemaInitializing: Sendable {
    func initializeSchema(_ schema: Schema, storeURL: URL, containerIdentifier: String) throws
}

/// The real initializer, backed by `NSPersistentCloudKitContainer`.
public struct CoreDataCloudKitSchemaInitializer: CloudKitSchemaInitializing {
    public init() {}

    public func initializeSchema(_ schema: Schema, storeURL: URL, containerIdentifier: String) throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: schema) else {
            throw CloudKitSchemaInitializationError.unconvertibleSchema
        }
        // The pool makes sure the Core Data stack is torn down before
        // SwiftData opens the same file.
        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: containerIdentifier)
            // Load synchronously so the store is ready before initializing.
            description.shouldAddStoreAsynchronously = false

            let container = NSPersistentCloudKitContainer(
                name: BlauCloud.syncedConfigurationName, managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            let loadError = LoadErrorBox()
            container.loadPersistentStores { _, error in
                loadError.error = error
            }
            if let error = loadError.error {
                throw error
            }
            defer {
                for store in container.persistentStoreCoordinator.persistentStores {
                    try? container.persistentStoreCoordinator.remove(store)
                }
            }
            try container.initializeCloudKitSchema(options: [])
        }
    }

    /// Receives the synchronous `loadPersistentStores` result.
    private final class LoadErrorBox {
        var error: (any Error)?
    }
}

public enum CloudKitSchemaInitializationError: Error, Equatable {
    /// SwiftData couldn't produce a Core Data model for the schema.
    case unconvertibleSchema
}

/// Decides when the development schema needs initializing, and remembers
/// which schema shape was last initialized on this device.
public struct CloudKitSchemaInitializationGate {
    /// `UserDefaults` key holding the fingerprint of the last initialized
    /// schema, per container.
    static func defaultsKey(containerIdentifier: String) -> String {
        "BlauCloudKitSchemaFingerprint.\(containerIdentifier)"
    }

    private let defaults: UserDefaults
    public let containerIdentifier: String

    public init(defaults: UserDefaults = .standard, containerIdentifier: String) {
        self.defaults = defaults
        self.containerIdentifier = containerIdentifier
    }

    /// Whether to initialize under `policy` for `schema`.
    public func shouldInitialize(_ schema: Schema, policy: SchemaInitializationPolicy) -> Bool {
        switch policy {
        case .never: false
        case .always: true
        case .whenSchemaChanges:
            defaults.string(forKey: Self.defaultsKey(containerIdentifier: containerIdentifier))
                != Self.fingerprint(of: schema)
        }
    }

    /// Records that `schema` was initialized successfully.
    public func markInitialized(_ schema: Schema) {
        defaults.set(Self.fingerprint(of: schema), forKey: Self.defaultsKey(containerIdentifier: containerIdentifier))
    }

    /// A stable fingerprint of the Core Data model SwiftData generates for
    /// `schema`: a SHA-256 over every entity's version hash, so any change to
    /// an entity, attribute or relationship changes it.
    public static func fingerprint(of schema: Schema) -> String {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: schema) else { return "unconvertible" }
        var hasher = SHA256()
        for (name, hash) in model.entityVersionHashesByName.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: hash)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
