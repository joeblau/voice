import BlauPersistence
import Foundation
import SwiftData
import Testing

@Suite("BlauMigrationPlan")
struct MigrationPlanTests {
    @Test func startsAtSchemaV1AndListsEveryVersion() {
        #expect(
            BlauMigrationPlan.schemas.map { $0.versionIdentifier }
                == [Schema.Version(1, 0, 0), Schema.Version(2, 0, 0), Schema.Version(3, 0, 0)])
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(SchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(SchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
    }

    @Test func thereIsOneStagePerConsecutivePairOfVersions() {
        #expect(BlauMigrationPlan.stages.count == BlauMigrationPlan.schemas.count - 1)
    }

    /// Stage `n` is a lightweight migration from schema `n` to schema
    /// `n + 1`: CloudKit only allows additive changes, which Core Data can
    /// always infer.
    @Test func everyStageIsLightweightBetweenConsecutiveVersions() {
        let schemas = BlauMigrationPlan.schemas.map { $0.versionIdentifier }
        for (index, stage) in BlauMigrationPlan.stages.enumerated() {
            guard case .lightweight(let from, let to) = stage else {
                Issue.record("Stage \(index) must be lightweight, got \(stage)")
                continue
            }
            #expect(from.versionIdentifier == schemas[index])
            #expect(to.versionIdentifier == schemas[index + 1])
        }
    }

    @Test func theCurrentSchemaIsTheNewestInThePlan() {
        #expect(BlauMigrationPlan.schemas.last?.versionIdentifier == CurrentSchema.versionIdentifier)
        #expect(BlauModelContainer.schema.version == CurrentSchema.versionIdentifier)
    }

    @Test func versionsAreStrictlyIncreasing() {
        let versions = BlauMigrationPlan.schemas.map { $0.versionIdentifier }
        #expect(versions == versions.sorted())
        #expect(Set(versions).count == versions.count)
    }

    @Test func anOnDiskStoreReopensThroughTheMigrationPlan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "blau-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")
        let id = UUID()

        do {
            let context = ModelContext(try BlauModelContainer.makeLocal(url: url))
            let conversation = Conversation(id: id, startedAt: Date(timeIntervalSinceReferenceDate: 0))
            context.insert(conversation)
            context.insert(Topic(conversation: conversation, startedAt: conversation.startedAt))
            try context.save()
        }

        let reopened = ModelContext(try BlauModelContainer.makeLocal(url: url))
        let conversations = try reopened.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.map(\.id) == [id])
        #expect(conversations.first?.topics?.count == 1)
    }

    @Test func inMemoryContainersAreIsolated() throws {
        let first = ModelContext(try BlauModelContainer.makeInMemory())
        first.insert(Conversation(startedAt: .distantPast))
        try first.save()

        let second = ModelContext(try BlauModelContainer.makeInMemory())
        #expect(try second.fetchCount(FetchDescriptor<Conversation>()) == 0)
    }
}
