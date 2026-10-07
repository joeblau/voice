/// Where the app's scene is in its lifecycle. Mirrors SwiftUI's `ScenePhase`
/// without importing SwiftUI, so BlauKit services can react to it and be
/// tested on macOS.
public enum AppPhase: String, CaseIterable, Sendable {
    /// In the foreground and interactive.
    case active
    /// In the foreground but not receiving events (app switcher, a system
    /// alert, Control Center), or on its way to or from the background.
    case inactive
    /// Not visible. Blau keeps running here during a conversation thanks to
    /// the `audio` background mode, so services decide what to keep alive.
    case background
}

/// One change of `AppPhase`.
public struct AppPhaseTransition: Hashable, Sendable {
    /// The phase before the change, or `nil` for the first phase after
    /// launch.
    public let from: AppPhase?
    public let to: AppPhase

    public init(from: AppPhase?, to: AppPhase) {
        self.from = from
        self.to = to
    }

    /// Whether this is the move into the foreground (`active`) from anywhere
    /// else, including launch.
    public var isBecomingActive: Bool { to == .active }

    /// Whether the app just left the screen.
    public var isEnteringBackground: Bool { to == .background && from != .background }

    /// Whether the app is coming back from the background (to `inactive` or
    /// `active`).
    public var isLeavingBackground: Bool { from == .background && to != .background }
}

extension AppPhaseTransition: CustomStringConvertible {
    public var description: String { "\(from?.rawValue ?? "launch") → \(to.rawValue)" }
}

/// A service that reacts to the app moving between foreground and
/// background: pausing work that isn't needed off screen, flushing state
/// before suspension, resuming on return.
///
/// Blau keeps a conversation running in the background (`audio` background
/// mode), so a participant must not stop a live session just because the app
/// was backgrounded. It should release what is idle and save what could be
/// lost if the process were suspended or killed.
public protocol AppLifecycleParticipant: Sendable {
    /// Called once per phase change, in order. The app keeps a background
    /// task open while participants handle a move to `background`, so a
    /// participant can finish a short save, but should return promptly.
    func appPhaseDidChange(_ transition: AppPhaseTransition) async
}
