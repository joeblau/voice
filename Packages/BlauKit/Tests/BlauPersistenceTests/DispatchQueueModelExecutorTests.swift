import BlauPersistence
import Dispatch
import Foundation
import SwiftData
import Testing

/// A minimal model actor on the queue executor, to check the executor alone.
private actor QueueBackedActor: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DispatchQueueModelExecutor(modelContainer: modelContainer, label: "test.queue-backed")
    }

    /// Inserts and saves a conversation and reports whether that ran on the
    /// main thread.
    func insertAndSave() throws -> Bool {
        modelContext.insert(Conversation(startedAt: Date(timeIntervalSinceReferenceDate: 0)))
        try modelContext.save()
        return Thread.isMainThread
    }

    func autosaveEnabled() -> Bool { modelContext.autosaveEnabled }

    /// The QoS class of the thread running this job.
    func currentQoS() -> UInt32 { qos_class_self().rawValue }
}

@Suite("DispatchQueueModelExecutor")
struct DispatchQueueModelExecutorTests {
    @MainActor
    @Test func jobsRunOffTheMainThreadEvenWhenCalledFromTheMainActor() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let actor = QueueBackedActor(modelContainer: container)  // created on the main thread too
        for _ in 0..<10 {
            #expect(try await actor.insertAndSave() == false)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Conversation>()) == 10)
    }

    @Test func autosaveIsOff() async throws {
        let actor = QueueBackedActor(modelContainer: try BlauModelContainer.makeInMemory())
        #expect(await actor.autosaveEnabled() == false)
    }

    @Test func jobsAreSerial() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let actor = QueueBackedActor(modelContainer: container)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask { try await actor.insertAndSave() }
            }
            for try await ranOnMain in group {
                #expect(!ranOnMain)
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Conversation>()) == 100)
    }

    @Test func jobsRunAtTheirTasksPriorityButNeverBelowTheFloor() async throws {
        let actor = QueueBackedActor(modelContainer: try BlauModelContainer.makeInMemory())
        let high = await Task(priority: .high) { await actor.currentQoS() }.value
        // Detached so awaiting it doesn't escalate it to the test's priority.
        let background = await Task.detached(priority: .background) { await actor.currentQoS() }.value
        #expect(high >= QOS_CLASS_USER_INITIATED.rawValue)
        #expect(background >= QOS_CLASS_UTILITY.rawValue)
    }

    @Test func checkIsolatedPassesOnTheQueue() throws {
        let executor = DispatchQueueModelExecutor(modelContainer: try BlauModelContainer.makeInMemory())
        executor.queue.sync { executor.checkIsolated() }
    }
}
