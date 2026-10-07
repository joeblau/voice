import Dispatch
import SwiftData

/// A `SerialModelExecutor` that runs every job on its own serial dispatch
/// queue, so a model actor that uses it never runs (or saves) on the main
/// thread.
///
/// The `@ModelActor` macro uses `DefaultSerialModelExecutor`, which runs a
/// job on whichever thread enqueued it when the executor is idle. Measured on
/// the macOS 27 / iOS 27 SDKs: every call into such an actor from
/// `@MainActor` code (a SwiftUI view, the composition root) runs the actor's
/// body, `save()` included, on the main thread. That is exactly the hitch the
/// write path exists to avoid, so Blau's model actors use this executor
/// instead (see `ConversationStore` and docs/data-model.md).
///
/// The `ModelContext` is created on the queue, and is only ever touched by
/// jobs on that queue.
public final class DispatchQueueModelExecutor: SerialModelExecutor, @unchecked Sendable {
    // @unchecked Sendable: `modelContext` is not Sendable, but it is only
    // used by jobs this executor runs, and those run one at a time on
    // `queue`. `queue` itself is thread-safe.

    public let modelContext: ModelContext

    /// The serial queue every job runs on.
    public let queue: DispatchSerialQueue

    /// The lowest QoS a job runs at. A job from a higher-priority task runs
    /// at that task's priority instead.
    public let floor: DispatchQoS.QoSClass

    /// - Parameters:
    ///   - modelContainer: The container to open a new `ModelContext` on.
    ///     Autosave is turned off; the owner decides when to save.
    ///   - label: The queue's label, shown in Instruments and crash reports.
    ///   - floor: The lowest QoS jobs run at. Each job otherwise runs at its
    ///     task's priority.
    public init(
        modelContainer: ModelContainer,
        label: String = "com.joeblau.blau.persistence",
        floor: DispatchQoS.QoSClass = .utility
    ) {
        let queue = DispatchSerialQueue(label: label, qos: DispatchQoS(qosClass: floor, relativePriority: 0))
        self.queue = queue
        self.floor = floor
        // Create the context on the queue, never on the caller's (possibly
        // main) thread, so it isn't tied to the main queue.
        self.modelContext = queue.sync {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            return context
        }
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority, floor: floor)
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
            job.runSynchronously(on: executor)
        }
    }

    /// The QoS a job runs at: its task's priority, but never below the
    /// executor's floor. Running a high-priority caller's job (for example
    /// the utterance committer awaiting `commitUtterance`) at the queue's
    /// lower QoS would be a priority inversion.
    static func qos(for priority: JobPriority, floor: DispatchQoS.QoSClass) -> DispatchQoS.QoSClass {
        // Swift task priorities share their raw values with Darwin's QoS
        // classes (high == USER_INITIATED == 0x19, and so on).
        let jobClass =
            DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(priority.rawValue))) ?? .unspecified
        return jobClass.rawValue.rawValue > floor.rawValue.rawValue ? jobClass : floor
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Lets `assumeIsolated` and the runtime's isolation checks recognise
    /// code already running on `queue`.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
