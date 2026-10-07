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
        return found.sorted { lhs, rhs in
            (lhs.entity, lhs.property ?? "", lhs.kind.rawValue) < (rhs.entity, rhs.property ?? "", rhs.kind.rawValue)
        }
    }
}
