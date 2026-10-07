import Observation

/// Delivers app phase changes to the services that care, in a safe order.
///
/// The app feeds every scene phase change into `update(to:)`. The
/// coordinator ignores repeats and tells each participant about the change:
///
/// - Moving to `active`, participants are called in the order given, lowest
///   layer first (persistence before audio, audio before transcription...),
///   so whatever a service depends on is ready before it resumes.
/// - Moving to `inactive` or `background`, they are called in reverse, so
///   the services that produce data flush it before the store they write to
///   saves.
///
/// Participants are called one at a time, and a change is only delivered
/// after every participant has handled the previous one, so a quick
/// background → foreground bounce can't reach a service out of order.
@MainActor
@Observable
public final class AppLifecycleCoordinator {
    /// The latest phase passed to `update(to:)`, or `nil` before the first.
    public private(set) var phase: AppPhase?

    /// Every change accepted so far, oldest first.
    public private(set) var history: [AppPhaseTransition] = []

    @ObservationIgnored private let participants: [any AppLifecycleParticipant]
    @ObservationIgnored private var delivery: Task<Void, Never>?

    /// - Parameter participants: The services to notify, lowest layer first.
    public init(participants: [any AppLifecycleParticipant]) {
        self.participants = participants
    }

    /// Records the move to `phase` and starts delivering it.
    ///
    /// - Returns: The transition, or `nil` when `phase` is the current phase
    ///   (nothing is delivered then).
    @discardableResult
    public func update(to phase: AppPhase) -> AppPhaseTransition? {
        guard phase != self.phase else { return nil }
        let transition = AppPhaseTransition(from: self.phase, to: phase)
        self.phase = phase
        history.append(transition)

        let ordered = transition.to == .active ? participants : participants.reversed()
        let previous = delivery
        delivery = Task {
            await previous?.value
            for participant in ordered {
                await participant.appPhaseDidChange(transition)
            }
        }
        return transition
    }

    /// Suspends until every accepted change has been delivered to every
    /// participant.
    public func waitUntilDelivered() async {
        // A change accepted while waiting chains onto the one awaited here,
        // so loop until the latest delivery is the one that finished.
        while let current = delivery {
            await current.value
            if delivery == current { return }
        }
    }
}
