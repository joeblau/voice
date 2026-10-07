import CoreData
import SwiftData

/// Checks a SwiftData schema against the rules CloudKit mirroring imposes.
///
/// SwiftData only reports these problems when a CloudKit-backed container
/// loads, which needs an iCloud account and entitlements. This check runs the
/// same rules on the Core Data model SwiftData generates for the schema, so a
/// unit test catches a violation on any machine. See
/// https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
public enum CloudKitCompatibility {
    /// One way a schema breaks CloudKit's rules.
    public struct Violation: Hashable, Sendable, CustomStringConvertible {
        public enum Kind: String, Hashable, Sendable {
            /// The schema couldn't be converted to a Core Data model.
            case unconvertibleSchema
            /// An attribute is neither optional nor defaulted.
            case attributeWithoutDefault
            /// An attribute is `@Attribute(.unique)` or the entity has a
            /// `#Unique` constraint.
            case uniquenessConstraint
            /// A relationship is not optional.
            case requiredRelationship
            /// A relationship has no inverse.
            case relationshipWithoutInverse
            /// A relationship uses the `.deny` delete rule.
            case denyDeleteRule
            /// A to-many relationship is ordered.
            case orderedRelationship
            /// The entity takes part in model inheritance.
            case inheritance
            /// A newer schema version dropped an entity an older one had.
            case removedEntity
            /// A newer schema version dropped a property an older one had.
            case removedProperty
            /// A newer schema version changed a property's type, optionality,
            /// destination, inverse, cardinality or ordering.
            case changedProperty
            /// A newer schema version turned an attribute's
            /// `.allowsCloudEncryption` on or off.
            case changedEncryption
        }

        public let kind: Kind
        public let entity: String
        /// The attribute or relationship, or `nil` for an entity-level rule.
        public let property: String?

        public init(_ kind: Kind, entity: String, property: String? = nil) {
            self.kind = kind
            self.entity = entity
            self.property = property
        }

        public var description: String {
            let location = property.map { "\(entity).\($0)" } ?? entity
            return "\(location): \(kind.rawValue)"
        }
    }

    /// Every violation in `schema`, sorted by entity, property and kind. Empty
    /// when the schema can sync through CloudKit.
    public static func violations(in schema: Schema) -> [Violation] {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: schema) else {
            return [Violation(.unconvertibleSchema, entity: "*")]
        }
        return violations(in: model)
    }

    /// Every violation in a versioned schema.
    public static func violations(in versionedSchema: any VersionedSchema.Type) -> [Violation] {
        violations(in: Schema(versionedSchema: versionedSchema))
    }

    /// Every violation in a Core Data model.
    public static func violations(in model: NSManagedObjectModel) -> [Violation] {
        var found: [Violation] = []
        for entity in model.entities {
            let name = entity.name ?? "?"
            if entity.superentity != nil || !entity.subentities.isEmpty {
                found.append(Violation(.inheritance, entity: name))
            }
            if !entity.uniquenessConstraints.isEmpty {
                found.append(Violation(.uniquenessConstraint, entity: name))
            }
            for (propertyName, attribute) in entity.attributesByName
            where !attribute.isTransient && !attribute.isOptional && attribute.defaultValue == nil {
                found.append(Violation(.attributeWithoutDefault, entity: name, property: propertyName))
            }
            for (propertyName, relationship) in entity.relationshipsByName {
                if !relationship.isOptional {
                    found.append(Violation(.requiredRelationship, entity: name, property: propertyName))
                }
                if relationship.inverseRelationship == nil {
                    found.append(Violation(.relationshipWithoutInverse, entity: name, property: propertyName))
                }
                if relationship.deleteRule == .denyDeleteRule {
                    found.append(Violation(.denyDeleteRule, entity: name, property: propertyName))
                }
                if relationship.isOrdered {
                    found.append(Violation(.orderedRelationship, entity: name, property: propertyName))
                }
            }
        }
        return sorted(found)
    }

    // MARK: - Additive-only evolution

    /// Every change from `older` to `newer` that CloudKit's production schema
    /// would reject. Empty when `newer` only adds entities and properties.
    ///
    /// Once a schema is deployed to production, record types and fields can
    /// be added but never removed, renamed or retyped, and a field's
    /// encryption can't change. So every entity of `older` must still exist
    /// in `newer` with every property unchanged (same Core Data version hash:
    /// name, type, optionality, and for relationships the destination,
    /// inverse, cardinality and ordering). Delete rules may change: they are
    /// local behavior, not part of the CloudKit schema. New properties must
    /// still be optional or defaulted, which `violations(in:)` checks.
    public static func breakingChanges(
        from older: any VersionedSchema.Type,
        to newer: any VersionedSchema.Type
    ) -> [Violation] {
        guard
            let olderModel = NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: older)),
            let newerModel = NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: newer))
        else {
            return [Violation(.unconvertibleSchema, entity: "*")]
        }
        return breakingChanges(from: olderModel, to: newerModel)
    }

    /// Every non-additive change between two Core Data models.
    public static func breakingChanges(from older: NSManagedObjectModel, to newer: NSManagedObjectModel) -> [Violation]
    {
        var found: [Violation] = []
        let newerEntities = newer.entitiesByName
        for oldEntity in older.entities {
            let name = oldEntity.name ?? "?"
            guard let newEntity = newerEntities[name] else {
                found.append(Violation(.removedEntity, entity: name))
                continue
            }
            let newProperties = newEntity.propertiesByName
            for (propertyName, oldProperty) in oldEntity.propertiesByName where !oldProperty.isTransient {
                guard let newProperty = newProperties[propertyName] else {
                    found.append(Violation(.removedProperty, entity: name, property: propertyName))
                    continue
                }
                if newProperty.versionHash != oldProperty.versionHash {
                    found.append(Violation(.changedProperty, entity: name, property: propertyName))
                }
                if let oldAttribute = oldProperty as? NSAttributeDescription,
                    let newAttribute = newProperty as? NSAttributeDescription,
                    oldAttribute.allowsCloudEncryption != newAttribute.allowsCloudEncryption
                {
                    found.append(Violation(.changedEncryption, entity: name, property: propertyName))
                }
            }
        }
        return sorted(found)
    }

    /// Every non-additive change between consecutive schemas of a migration
    /// plan, oldest first.
    public static func breakingChanges(in plan: any SchemaMigrationPlan.Type) -> [Violation] {
        let schemas = plan.schemas
        return zip(schemas, schemas.dropFirst()).flatMap { older, newer in
            breakingChanges(from: older, to: newer)
        }
    }

    private static func sorted(_ violations: [Violation]) -> [Violation] {
        violations.sorted { lhs, rhs in
            (lhs.entity, lhs.property ?? "", lhs.kind.rawValue) < (rhs.entity, rhs.property ?? "", rhs.kind.rawValue)
        }
    }
}
