import BlauTelemetry
import UIKit
import os

/// Tells the background services when the device locks and unlocks (#26).
///
/// "Locked" is protected data becoming unavailable, which iOS posts about
/// ten seconds after the screen locks, and only on a device with a
/// passcode. The scene phase already says Blau is off screen; this only
/// refines `background` into `locked` for the inference monitor and the
/// conversation statistics.
@MainActor
final class DeviceLockObserver {
    private var observers: [any NSObjectProtocol] = []
    private let onChange: @MainActor (Bool) -> Void

    /// - Parameter onChange: Called with `true` when the device locks and
    ///   `false` when it unlocks, on the main actor.
    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Starts observing and reports the current state once.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(locked: true) }
            },
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(locked: false) }
            },
        ]
        report(locked: !UIApplication.shared.isProtectedDataAvailable)
    }

    private func report(locked: Bool) {
        Log.ui.notice("Device \(locked ? "locked" : "unlocked", privacy: .public)")
        onChange(locked)
    }
}
