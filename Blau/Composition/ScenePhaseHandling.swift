import BlauCore
import BlauRealtime
import BlauTelemetry
import SwiftData
import SwiftUI
import os

#if canImport(UIKit)
    import UIKit
#endif

extension AppPhase {
    /// The BlauKit phase for a SwiftUI scene phase, or `nil` for a phase this
    /// SDK doesn't know about.
    init?(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: return nil
        }
    }
}

extension AppEnvironment {
    /// Feeds a scene phase change to the services.
    ///
    /// Becoming active, it also refreshes the xAI key with `xai.refresh()`,
    /// which does nothing until `start()` has loaded the key, so the
    /// launch-time `inactive → active` can't race the DEBUG key seeding.
    /// Moving to the background, the app asks iOS for extra running
    /// time until every service has handled the change, so the store's save
    /// and any other flushing finish before the process can be suspended.
    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard let phase = AppPhase(scenePhase) else {
            Log.ui.error("Ignoring an unknown scene phase: \(String(describing: scenePhase), privacy: .public)")
            return
        }
        guard let transition = lifecycle.update(to: phase) else { return }
        Log.ui.notice("Scene phase \(transition.description, privacy: .public)")

        if transition.isBecomingActive {
            // Pick up a key added or removed on another device (iCloud
            // Keychain).
            xaiRefresh = Task { await xai.refresh() }
        }

        #if canImport(UIKit)
            if transition.isEnteringBackground {
                let assertion = BackgroundTaskAssertion(name: "blau.lifecycle.background")
                Task {
                    await lifecycle.waitUntilDelivered()
                    assertion.end()
                }
            }
        #endif
    }
}

#if canImport(UIKit)
    /// Extra background running time from `UIApplication`, held until `end()`
    /// or until iOS says the time is up.
    @MainActor
    final class BackgroundTaskAssertion {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        init(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                Log.ui.error("Background time expired before the services finished handling the change")
                self?.end()
            }
        }

        /// Gives the time back. Safe to call more than once.
        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif

/// Puts `environment` and the objects views read most into the SwiftUI
/// environment: the `AppEnvironment` itself, its `FeatureFlags`, its
/// `AppLifecycleCoordinator`, its `XAIAccount` and its SwiftData container.
struct AppEnvironmentModifier: ViewModifier {
    let environment: AppEnvironment

    func body(content: Content) -> some View {
        content
            .environment(environment)
            .environment(environment.flags)
            .environment(environment.lifecycle)
            .environment(environment.xai.account)
            .modelContainer(environment.modelContainer)
    }
}

extension View {
    /// Injects `environment` (see `AppEnvironmentModifier`). The app applies
    /// it to its root view; previews apply it with `AppEnvironment.preview()`.
    func appEnvironment(_ environment: AppEnvironment) -> some View {
        modifier(AppEnvironmentModifier(environment: environment))
    }
}
