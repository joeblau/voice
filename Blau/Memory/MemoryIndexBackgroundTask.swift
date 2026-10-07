import BlauMemory
import BlauTelemetry
import Foundation
import os

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

/// The memory index's background processing task (#63): finishes a full
/// rebuild (new device, recreated index, model change) or an embedding
/// backlog while the app is in the background.
///
/// The indexer runs in the foreground too and checkpoints after every
/// step, so this task only has to give it time: it waits until the
/// indexer is idle, and on expiration stops waiting and lets iOS suspend
/// the process mid-step. The next run (in the foreground or another
/// task) resumes from the checkpoint. The identifier is listed in
/// `BGTaskSchedulerPermittedIdentifiers` and the `processing` background
/// mode is declared in `project.yml`. See docs/memory-indexer.md.
enum MemoryIndexBackgroundTask {
    static let identifier = "com.joeblau.blau.memory-index"

    #if canImport(BackgroundTasks) && os(iOS)
        /// Registers the launch handler. Call once, before the app finishes
        /// launching (iOS kills an app that registers an identifier twice).
        ///
        /// - Returns: Whether iOS accepted it (the identifier must be in
        ///   Info.plist).
        @discardableResult
        nonisolated static func register(_ indexing: MemoryIndexingController) -> Bool {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
                @Sendable task in
                Log.memory.notice("Memory index background task started")
                let completion = TaskCompletion(task)
                let work = Task { @MainActor in
                    let finished = await indexing.performBackgroundWork()
                    Log.memory.notice(
                        "Memory index background task \(finished ? "finished" : "stopped", privacy: .public)")
                    if !finished { schedule() }
                    completion.finish(success: finished)
                }
                task.expirationHandler = { work.cancel() }
            }
            if !registered {
                Log.memory.error("The memory index background task identifier is not permitted in Info.plist")
            }
            return registered
        }

        /// Asks iOS for background time if a rebuild or an embedding
        /// backlog is waiting. Called when the app leaves the foreground.
        @MainActor
        static func scheduleIfNeeded(_ indexing: MemoryIndexingController) {
            guard indexing.needsBackgroundWork else { return }
            schedule()
        }

        /// Submits the request (replacing a pending one). Runs off the main
        /// thread, as BackgroundTasks asks.
        nonisolated static func schedule() {
            Task.detached(priority: .utility) {
                let request = BGProcessingTaskRequest(identifier: identifier)
                // Everything is on the device; the indexer itself defers to
                // the thermal and power policy (#75), so it may run on
                // battery.
                request.requiresNetworkConnectivity = false
                request.requiresExternalPower = false
                do {
                    if #available(iOS 27, *) {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } else {
                        try BGTaskScheduler.shared.submit(request)
                    }
                    Log.memory.info("Scheduled the memory index background task")
                } catch {
                    Log.memory.error(
                        "Scheduling the memory index background task failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        /// `BGTask` isn't annotated `Sendable`, but `setTaskCompleted(success:)`
        /// may be called from any thread (the launch handler itself runs on
        /// a background queue). The box exposes only that call.
        private final class TaskCompletion: @unchecked Sendable {
            private let task: BGTask

            init(_ task: BGTask) {
                self.task = task
            }

            func finish(success: Bool) {
                task.setTaskCompleted(success: success)
            }
        }
    #endif
}
