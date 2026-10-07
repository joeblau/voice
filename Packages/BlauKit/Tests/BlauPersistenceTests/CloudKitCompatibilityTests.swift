import BlauPersistence
import CoreData
import Foundation
import SwiftData
import Testing

@Suite("CloudKit compatibility")
struct CloudKitCompatibilityTests {
    /// The schema the app opens. Older versions are covered by the plan-wide
    /// tests.
    private let schema = Schema(versionedSchema: CurrentSchema.self)

    @Test func theCurrentSchemaIsV2() {
        #expect(CurrentSchema.versionIdentifier == SchemaV2.versionIdentifier)
    }

    @Test func schemaV1HasNoViolations() {
        let violations = CloudKitCompatibility.violations(in: SchemaV1.self)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func schemaV2HasNoViolations() {
        let violations = CloudKitCompatibility.violations(in: SchemaV2.self)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func everyMigrationPlanSchemaHasNoViolations() {
        for version in BlauMigrationPlan.schemas {
            let violations = CloudKitCompatibility.violations(in: version)
            #expect(violations.isEmpty, "\(version.versionIdentifier): \(violations)")
        }
    }

    /// CloudKit's production schema is additive only, so each version must
    /// keep every entity and property of the one before it.
    @Test func everyMigrationPlanStepIsAdditive() {
        let changes = CloudKitCompatibility.breakingChanges(in: BlauMigrationPlan.self)
        #expect(changes.isEmpty, "\(changes)")
        #expect(CloudKitCompatibility.breakingChanges(from: SchemaV1.self, to: SchemaV2.self).isEmpty)
    }

    @Test func schemaV1HasTheExpectedEntities() {
        #expect(
            Set(Schema(versionedSchema: SchemaV1.self).entities.map(\.name))
                == ["Conversation", "Topic", "Utterance", "VoiceProfile", "VoiceEnrollmentSet"])
    }

    @Test func schemaV2AddsTheMemoryEntities() {
        #expect(
            Set(Schema(versionedSchema: SchemaV2.self).entities.map(\.name))
                == [
                    "Conversation", "Topic", "Utterance", "VoiceProfile", "VoiceEnrollmentSet",
                    "Document", "CollectionItem", "MemoryEntity", "Fact", "ProfileBlock",
                ])
    }

    @Test func noAttributeIsUnique() {
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) has #Unique constraints")
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name) is unique")
            }
        }
    }

    @Test func everyAttributeIsOptionalOrDefaulted() {
        for entity in schema.entities {
            for attribute in entity.attributes {
                #expect(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "\(entity.name).\(attribute.name) needs a default value")
            }
        }
    }

    @Test func everyRelationshipIsOptionalWithAnInverseAndNoDenyRule() throws {
        let relationships = schema.entities.flatMap { entity in entity.relationships.map { (entity.name, $0) } }
        #expect(relationships.count == 12)
        for (entity, relationship) in relationships {
            #expect(relationship.isOptional, "\(entity).\(relationship.name) must be optional")
            #expect(!relationship.isUnique, "\(entity).\(relationship.name) is unique")
            #expect(relationship.deleteRule != .deny, "\(entity).\(relationship.name) uses .deny")
        }

        // SwiftData records the inverse on at least one side; Core Data (what
        // CloudKit mirroring reads) must have it on both.
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: schema))
        for entity in model.entities {
            for (name, relationship) in entity.relationshipsByName {
                #expect(relationship.inverseRelationship != nil, "\(entity.name ?? "?").\(name) has no inverse")
            }
        }
    }

    @Test func modelsAreFlat() {
        for entity in schema.entities {
            #expect(entity.superentityName == nil, "\(entity.name) inherits from \(entity.superentityName ?? "")")
            #expect(entity.subentities.isEmpty, "\(entity.name) has subentities")
        }
    }

    @Test func deleteRulesMatchTheDesign() {
        func rule(_ entity: String, _ relationship: String) -> Schema.Relationship.DeleteRule? {
            schema.entitiesByName[entity]?.relationshipsByName[relationship]?.deleteRule
        }
        #expect(rule("Conversation", "topics") == .cascade)
        #expect(rule("Conversation", "utterances") == .cascade)
        #expect(rule("Topic", "utterances") == .nullify)
        #expect(rule("VoiceProfile", "enrollmentSets") == .cascade)
        #expect(rule("Topic", "conversation") == .nullify)
        #expect(rule("Utterance", "conversation") == .nullify)
        #expect(rule("Utterance", "topic") == .nullify)
        #expect(rule("VoiceEnrollmentSet", "profile") == .nullify)
        #expect(rule("Document", "collectionItems") == .cascade)
        #expect(rule("CollectionItem", "document") == .nullify)
        #expect(rule("MemoryEntity", "facts") == .cascade)
        #expect(rule("Fact", "subject") == .nullify)
    }

    /// The memory models hold text like the utterances they come from, so
    /// none of their fields is end-to-end encrypted (a choice CloudKit fixes
    /// once a field is deployed; see docs/data-model.md).
    @Test func memoryFieldsAreNotCloudEncrypted() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: schema))
        for name in ["Document", "CollectionItem", "MemoryEntity", "Fact", "ProfileBlock"] {
            let entity = try #require(model.entitiesByName[name])
            for (property, attribute) in entity.attributesByName {
                #expect(!attribute.allowsCloudEncryption, "\(name).\(property)")
            }
        }
    }

    @Test func voiceprintVectorsUseCloudEncryption() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: schema))
        let profile = try #require(model.entitiesByName["VoiceProfile"]?.attributesByName["centroid"])
        let set = try #require(model.entitiesByName["VoiceEnrollmentSet"]?.attributesByName["embeddings"])
        #expect(profile.allowsCloudEncryption)
        #expect(set.allowsCloudEncryption)
    }

    // MARK: - The check itself

    @Test func detectsEveryKindOfViolation() {
        let violations = CloudKitCompatibility.violations(
            in: Schema([IncompatibleParent.self, IncompatibleChild.self]))
        let kinds = Set(violations.map(\.kind))
        #expect(kinds.contains(.uniquenessConstraint), "\(violations)")
        #expect(kinds.contains(.attributeWithoutDefault), "\(violations)")
        #expect(kinds.contains(.denyDeleteRule), "\(violations)")
        #expect(kinds.contains(.relationshipWithoutInverse), "\(violations)")
        #expect(
            violations.contains(
                CloudKitCompatibility.Violation(
                    .attributeWithoutDefault, entity: "IncompatibleParent", property: "label")))
        #expect(
            violations.contains(
                CloudKitCompatibility.Violation(.denyDeleteRule, entity: "IncompatibleParent", property: "children")))
    }

    @Test func detectsCoreDataLevelViolations() {
        let parent = NSEntityDescription()
        parent.name = "Parent"
        let child = NSEntityDescription()
        child.name = "Child"
        let sub = NSEntityDescription()
        sub.name = "SubParent"
        parent.subentities = [sub]

        let children = NSRelationshipDescription()
        children.name = "children"
        children.destinationEntity = child
        children.maxCount = 0
        children.isOrdered = true
        children.isOptional = false
        let owner = NSRelationshipDescription()
        owner.name = "owner"
        owner.destinationEntity = parent
        owner.maxCount = 1
        children.inverseRelationship = owner
        owner.inverseRelationship = children
        parent.properties = [children]
        child.properties = [owner]

        let model = NSManagedObjectModel()
        model.entities = [parent, child, sub]
        let kinds = Set(CloudKitCompatibility.violations(in: model).map(\.kind))
        #expect(kinds == [.inheritance, .orderedRelationship, .requiredRelationship])
    }

    @Test func detectsNonAdditiveSchemaChanges() {
        func attribute(
            _ name: String, _ type: NSAttributeDescription.AttributeType, optional: Bool = true,
            encrypted: Bool = false
        ) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.type = type
            attribute.isOptional = optional
            attribute.allowsCloudEncryption = encrypted
            return attribute
        }
        func entity(_ name: String, _ properties: [NSPropertyDescription]) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.properties = properties
            return entity
        }

        let older = NSManagedObjectModel()
        older.entities = [
            entity(
                "Note",
                [
                    attribute("title", .string), attribute("count", .integer64), attribute("secret", .binaryData),
                    attribute("kept", .date), attribute("renamed", .string),
                ]),
            entity("Gone", [attribute("value", .string)]),
        ]
        let newer = NSManagedObjectModel()
        newer.entities = [
            entity(
                "Note",
                [
                    attribute("title", .string, optional: false),  // optionality changed
                    attribute("count", .double),  // retyped
                    attribute("secret", .binaryData, encrypted: true),  // encryption turned on
                    attribute("kept", .date),  // unchanged
                    attribute("newName", .string),  // `renamed` dropped, a new field added
                ]),
            entity("Added", [attribute("value", .string)]),
        ]

        let changes = CloudKitCompatibility.breakingChanges(from: older, to: newer)
        #expect(
            changes == [
                CloudKitCompatibility.Violation(.removedEntity, entity: "Gone"),
                CloudKitCompatibility.Violation(.changedProperty, entity: "Note", property: "count"),
                CloudKitCompatibility.Violation(.removedProperty, entity: "Note", property: "renamed"),
                CloudKitCompatibility.Violation(.changedEncryption, entity: "Note", property: "secret"),
                CloudKitCompatibility.Violation(.changedProperty, entity: "Note", property: "title"),
            ])
        #expect(CloudKitCompatibility.breakingChanges(from: older, to: older).isEmpty)
        #expect(CloudKitCompatibility.breakingChanges(from: newer, to: newer).isEmpty)
    }

    @Test func aRelationshipChangeIsBreakingButADeleteRuleChangeIsNot() {
        func model(maxCount: Int, deleteRule: NSDeleteRule) -> NSManagedObjectModel {
            let parent = NSEntityDescription()
            parent.name = "Parent"
            let child = NSEntityDescription()
            child.name = "Child"
            let children = NSRelationshipDescription()
            children.name = "children"
            children.destinationEntity = child
            children.maxCount = maxCount
            children.deleteRule = deleteRule
            let owner = NSRelationshipDescription()
            owner.name = "owner"
            owner.destinationEntity = parent
            owner.maxCount = 1
            children.inverseRelationship = owner
            owner.inverseRelationship = children
            parent.properties = [children]
            child.properties = [owner]
            let model = NSManagedObjectModel()
            model.entities = [parent, child]
            return model
        }

        let toMany = model(maxCount: 0, deleteRule: .cascadeDeleteRule)
        #expect(
            CloudKitCompatibility.breakingChanges(from: toMany, to: model(maxCount: 0, deleteRule: .nullifyDeleteRule))
                .isEmpty)
        #expect(
            CloudKitCompatibility.breakingChanges(from: toMany, to: model(maxCount: 1, deleteRule: .cascadeDeleteRule))
                == [CloudKitCompatibility.Violation(.changedProperty, entity: "Parent", property: "children")])
    }

    @Test func violationsDescribeTheirLocation() {
        #expect(
            CloudKitCompatibility.Violation(.denyDeleteRule, entity: "Topic", property: "utterances").description
                == "Topic.utterances: denyDeleteRule")
        #expect(CloudKitCompatibility.Violation(.inheritance, entity: "Topic").description == "Topic: inheritance")
    }
}

// MARK: - Fixtures that break CloudKit's rules on purpose

@Model
final class IncompatibleParent {
    @Attribute(.unique) var key: String = ""
    var label: String
    @Relationship(deleteRule: .deny, inverse: \IncompatibleChild.parent)
    var children: [IncompatibleChild]? = []
    /// A one-way link with no inverse.
    var favorite: IncompatibleChild?

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

@Model
final class IncompatibleChild {
    var parent: IncompatibleParent?

    init() {}
}
