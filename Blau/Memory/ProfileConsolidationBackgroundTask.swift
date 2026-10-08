import BlauMemory
import BlauTelemetry
import Foundation
import os

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

/// The profile's sleep-time consolidation (#67) as a background processing
/// task: iOS runs it while the phone is idle and charging, typically
/// overnight, with the network up.
///
/// The task asks the consolidator whether a run is due (weekly, or sooner
/// after enough new facts) and runs it; either way it schedules the next
/// check. The identifier is listed in `BGTaskSchedulerPermittedIdentifiers`
/// and the `processing` background mode is declared in `project.yml`. See
/// docs/memory-profile.md.
enum ProfileConsolidationBackgroundTask {
    static let identifier = "com.joeblau.blau.memory-profile"

    #if canImport(BackgroundTasks) && os(iOS)
        /// Registers the launch handler. Call once, before the app finishes
        /// launching (iOS kills an app that registers an identifier twice).
        ///
        /// - Returns: Whether iOS accepted it (the identifier must be in
        ///   Info.plist).
        @discardableResult
        nonisolated static func register(_ profile: ProfileMemory) -> Bool {
            let consolidator = profile.consolidator
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
                @Sendable task in
                Log.memory.notice("Profile consolidation background task started")
                let completion = TaskCompletion(task)
                let work = Task(priority: .utility) {
                    let outcome = await consolidator.consolidateIfDue()
                    Log.memory.notice(
                        "Profile consolidation background task finished: \(String(describing: outcome), privacy: .public)"
                    )
                    let succeeded: Bool
                    switch outcome {
                    case .failed: succeeded = false
                    case .skipped(.deferred): succeeded = false
                    default: succeeded = true
                    }
                    await schedule(profile)
                    completion.finish(success: succeeded && !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
            if !registered {
                Log.memory.error("The profile consolidation task identifier is not permitted in Info.plist")
            }
            return registered
        }

        /// Asks iOS to run the task once the next consolidation may be due.
        /// Called when the app leaves the foreground and after each run.
        static func schedule(_ profile: ProfileMemory) async {
            guard profile.schedulesBackgroundWork, let nextCheck = await profile.nextBackgroundCheck() else { return }
            await submit(earliestBeginDate: nextCheck)
        }

        /// Submits the request (replacing a pending one), off the main
        /// thread as BackgroundTasks asks.
        private nonisolated static func submit(earliestBeginDate: Date) async {
            await Task.detached(priority: .utility) {
                let request = BGProcessingTaskRequest(identifier: identifier)
                request.earliestBeginDate = earliestBeginDate
                // The rewrite is an xAI request. External power makes it
                // "sleep-time": iOS runs it while the phone charges, not on
                // the battery during the day.
                request.requiresNetworkConnectivity = true
                request.requiresExternalPower = true
                do {
                    if #available(iOS 27, *) {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } else {
                        try BGTaskScheduler.shared.submit(request)
                    }
                    Log.memory.info("Scheduled profile consolidation for \(earliestBeginDate, privacy: .public)")
                } catch {
                    Log.memory.error(
                        "Scheduling profile consolidation failed: \(String(describing: error), privacy: .public)")
                }
            }.value
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
