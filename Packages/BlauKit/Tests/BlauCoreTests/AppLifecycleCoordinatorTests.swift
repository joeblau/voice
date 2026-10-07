import BlauCore
import Synchronization
import Testing

/// Records, across participants, the order they were told about changes.
private final class CallLog: Sendable {
    private let calls = Mutex<[String]>([])

    var entries: [String] { calls.withLock { $0 } }

    func append(_ entry: String) {
        calls.withLock { $0.append(entry) }
    }
}

private struct Participant: AppLifecycleParticipant {
    let name: String
    let log: CallLog
    var delay: Int = 0

    func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        // Yield a few times so a slow participant gives later deliveries a
        // chance to overtake it if ordering were broken.
        for _ in 0..<delay { await Task.yield() }
        log.append("\(name):\(transition.to.rawValue)")
    }
}

@Suite("AppPhaseTransition")
struct AppPhaseTransitionTests {
    @Test func classifiesTransitions() {
        let launch = AppPhaseTransition(from: nil, to: .active)
        #expect(launch.isBecomingActive)
        #expect(!launch.isEnteringBackground)
        #expect(!launch.isLeavingBackground)
        #expect(launch.description == "launch → active")

        let backgrounding = AppPhaseTransition(from: .inactive, to: .background)
        #expect(backgrounding.isEnteringBackground)
        #expect(!backgrounding.isBecomingActive)

        let returning = AppPhaseTransition(from: .background, to: .inactive)
        #expect(returning.isLeavingBackground)
        #expect(!returning.isEnteringBackground)
    }
}

@Suite("AppLifecycleCoordinator")
@MainActor
struct AppLifecycleCoordinatorTests {
    @Test func firstUpdateComesFromLaunch() async {
        let log = CallLog()
        let coordinator = AppLifecycleCoordinator(participants: [Participant(name: "a", log: log)])
        #expect(coordinator.phase == nil)

        let transition = coordinator.update(to: .active)
        #expect(transition == AppPhaseTransition(from: nil, to: .active))
        #expect(coordinator.phase == .active)
        await coordinator.waitUntilDelivered()
        #expect(log.entries == ["a:active"])
    }

    @Test func repeatedPhasesAreIgnored() async {
        let log = CallLog()
        let coordinator = AppLifecycleCoordinator(participants: [Participant(name: "a", log: log)])
        coordinator.update(to: .active)
        #expect(coordinator.update(to: .active) == nil)
        await coordinator.waitUntilDelivered()
        #expect(log.entries == ["a:active"])
        #expect(coordinator.history.count == 1)
    }

    @Test func activationGoesLowestLayerFirstAndBackgroundingInReverse() async {
        let log = CallLog()
        let coordinator = AppLifecycleCoordinator(participants: [
            Participant(name: "persistence", log: log),
            Participant(name: "audio", log: log),
            Participant(name: "realtime", log: log),
        ])
        coordinator.update(to: .active)
        await coordinator.waitUntilDelivered()
        coordinator.update(to: .background)
        await coordinator.waitUntilDelivered()

        #expect(
            log.entries == [
                "persistence:active", "audio:active", "realtime:active",
                "realtime:background", "audio:background", "persistence:background",
            ]
        )
    }

    @Test func rapidChangesAreDeliveredInOrder() async {
        let log = CallLog()
        let coordinator = AppLifecycleCoordinator(participants: [
            Participant(name: "slow", log: log, delay: 50),
            Participant(name: "fast", log: log),
        ])
        // A launch followed by a quick trip to the background and back,
        // without waiting in between.
        for phase: AppPhase in [.active, .inactive, .background, .inactive, .active] {
            coordinator.update(to: phase)
        }
        await coordinator.waitUntilDelivered()

        #expect(
            log.entries == [
                "slow:active", "fast:active",
                "fast:inactive", "slow:inactive",
                "fast:background", "slow:background",
                "fast:inactive", "slow:inactive",
                "slow:active", "fast:active",
            ]
        )
        #expect(coordinator.history.map(\.to) == [.active, .inactive, .background, .inactive, .active])
        #expect(coordinator.history.map(\.from) == [nil, .active, .inactive, .background, .inactive])
    }

    @Test func worksWithNoParticipants() async {
        let coordinator = AppLifecycleCoordinator(participants: [])
        coordinator.update(to: .background)
        await coordinator.waitUntilDelivered()
        #expect(coordinator.phase == .background)
    }

    @Test func servicesWithoutLifecycleNeedsUseTheDefaultNoOp() async {
        let coordinator = AppLifecycleCoordinator(participants: [UnavailableService(subsystem: "audio")])
        coordinator.update(to: .active)
        await coordinator.waitUntilDelivered()
        #expect(coordinator.phase == .active)
    }
}
