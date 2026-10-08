import BlauCore
import Foundation
import Testing

/// The prerequisites a test controls, read by the flow on every decision.
@MainActor
private final class Conditions {
    var current = OnboardingPrerequisites()
}

@MainActor
private func makeFlow(
    _ conditions: Conditions,
    store: InMemoryOnboardingProgressStore = InMemoryOnboardingProgressStore(),
    now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)
) -> OnboardingFlow {
    OnboardingFlow(store: store, prerequisites: { conditions.current }, now: { now })
}

/// Advances through every step on screen and returns them in order.
@MainActor
private func walk(_ flow: OnboardingFlow, limit: Int = 20) -> [OnboardingStep] {
    var shown: [OnboardingStep] = []
    while let step = flow.step, shown.count < limit {
        shown.append(step)
        flow.advance()
    }
    return shown
}

@Suite("Onboarding steps")
struct OnboardingStepTests {
    @Test func theStepsFollowTheIssueOrder() {
        #expect(
            OnboardingStep.allCases == [
                .welcome, .xaiAccount, .microphone, .speechModels, .iCloud, .voiceEnrollment, .aboutYou, .ready,
            ])
    }

    @Test func onlyTheKeyTheMicrophoneAndTheModelsAreRequirements() {
        #expect(OnboardingStep.requirements == [.xaiAccount, .microphone, .speechModels])
    }

    @Test func prerequisitesReadAndWriteEachStep() {
        var prerequisites = OnboardingPrerequisites()
        for (index, step) in OnboardingStep.allCases.enumerated() where step != .welcome && step != .ready {
            let value = OnboardingRequirement.allCases[index % OnboardingRequirement.allCases.count]
            prerequisites[step] = value
            #expect(prerequisites[step] == value)
        }
        // The pages without a prerequisite are never "already done".
        prerequisites[.welcome] = .satisfied
        #expect(prerequisites[.welcome] == .missing)
        #expect(prerequisites[.ready] == .missing)
    }

    @Test func missingRequirementsIgnoreUnknownAndInProgress() {
        let prerequisites = OnboardingPrerequisites(
            xaiAccount: .unknown, microphone: .missing, speechModels: .inProgress, iCloud: .missing,
            voiceEnrollment: .missing, aboutYou: .missing)
        #expect(prerequisites.missingRequirements == [.microphone])
        #expect(OnboardingPrerequisites.satisfied.missingRequirements.isEmpty)
    }
}

@Suite("Onboarding progress")
struct OnboardingProgressTests {
    private final class ScratchDefaults {
        let suiteName = "com.joeblau.blau.tests.onboarding.\(UUID().uuidString)"

        deinit {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    @Test func roundTripsThroughUserDefaults() {
        let scratch = ScratchDefaults()
        let store = UserDefaultsOnboardingProgressStore(suiteName: scratch.suiteName)
        #expect(store.load() == .fresh)

        let progress = OnboardingProgress(
            visited: [.welcome, .xaiAccount], current: .microphone,
            finishedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        store.save(progress)
        #expect(UserDefaultsOnboardingProgressStore(suiteName: scratch.suiteName).load() == progress)

        store.reset()
        #expect(store.load() == .fresh)
    }

    @Test func unknownStepsFromANewerVersionAreDropped() throws {
        let json = #"{"visited":["welcome","holograms","microphone"],"current":"holograms"}"#
        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))
        #expect(progress.visited == [.welcome, .microphone])
        #expect(progress.current == nil)
        #expect(!progress.isFinished)
    }

    @Test func corruptDataReadsAsAFreshStart() {
        let scratch = ScratchDefaults()
        UserDefaults(suiteName: scratch.suiteName)?.set(
            Data("not json".utf8), forKey: UserDefaultsOnboardingProgressStore.defaultKey)
        #expect(UserDefaultsOnboardingProgressStore(suiteName: scratch.suiteName).load() == .fresh)
    }
}

@MainActor
@Suite("Onboarding flow: setup")
struct OnboardingSetupTests {
    @Test func aFreshInstallWalksEveryStepThenFinishes() {
        let conditions = Conditions()
        conditions.current = OnboardingPrerequisites(
            xaiAccount: .missing, microphone: .missing, speechModels: .inProgress, iCloud: .missing,
            voiceEnrollment: .missing, aboutYou: .missing)
        let store = InMemoryOnboardingProgressStore()
        let finished = Date(timeIntervalSinceReferenceDate: 42)
        let flow = makeFlow(conditions, store: store, now: finished)

        #expect(flow.mode == .setup)
        #expect(flow.isPresented)
        #expect(flow.step == .welcome)
        #expect(flow.remainingSteps == OnboardingStep.allCases)

        #expect(walk(flow) == OnboardingStep.allCases)
        #expect(!flow.isPresented)
        #expect(flow.mode == .recovery)
        #expect(store.load().finishedAt == finished)
        #expect(store.load().current == nil)
        #expect(store.load().visited == Set(OnboardingStep.allCases))
    }

    @Test func stepsAlreadyDoneArePassedOver() {
        // A second device: the key arrived through iCloud Keychain and the
        // voiceprint through iCloud.
        let conditions = Conditions()
        conditions.current = OnboardingPrerequisites(
            xaiAccount: .satisfied, microphone: .missing, speechModels: .missing, iCloud: .satisfied,
            voiceEnrollment: .satisfied, aboutYou: .satisfied)
        let flow = makeFlow(conditions)
        #expect(flow.remainingSteps == [.welcome, .microphone, .speechModels, .ready])
        #expect(walk(flow) == [.welcome, .microphone, .speechModels, .ready])
    }

    @Test func unknownStepsAreShown() {
        let conditions = Conditions()
        let flow = makeFlow(conditions)
        #expect(walk(flow) == OnboardingStep.allCases)
    }

    @Test func theNextStepIsChosenWithTheLatestPrerequisites() {
        let conditions = Conditions()
        conditions.current = OnboardingPrerequisites(microphone: .missing, speechModels: .inProgress)
        let flow = makeFlow(conditions)
        flow.advance()  // welcome
        #expect(flow.step == .xaiAccount)
        // The models finish downloading while the user types the key.
        conditions.current.speechModels = .satisfied
        flow.advance()
        #expect(flow.step == .microphone)
        flow.advance()
        #expect(flow.step == .iCloud)
    }

    @Test func remainingStepsShrinkAsPrerequisitesAreMet() {
        let conditions = Conditions()
        let flow = makeFlow(conditions)
        #expect(flow.remainingSteps.count == OnboardingStep.allCases.count)
        conditions.current.iCloud = .satisfied
        conditions.current.aboutYou = .satisfied
        #expect(flow.remainingSteps == [.welcome, .xaiAccount, .microphone, .speechModels, .voiceEnrollment, .ready])
    }

    @Test func skippingARequirementStillMovesOn() {
        // Setup never traps the user: every step can be passed over.
        let conditions = Conditions()
        conditions.current = OnboardingPrerequisites(
            xaiAccount: .missing, microphone: .missing, speechModels: .missing, iCloud: .missing,
            voiceEnrollment: .missing, aboutYou: .missing)
        let flow = makeFlow(conditions)
        #expect(walk(flow).last == .ready)
        #expect(!flow.isPresented)
    }

    @Test func goingBackReturnsToThePreviousStep() {
        let conditions = Conditions()
        let flow = makeFlow(conditions)
        #expect(!flow.canGoBack)
        flow.advance()
        flow.advance()
        #expect(flow.step == .microphone)
        #expect(flow.completedCount == 2)
        flow.goBack()
        #expect(flow.step == .xaiAccount)
        flow.goBack()
        #expect(flow.step == .welcome)
        #expect(!flow.canGoBack)
        flow.goBack()
        #expect(flow.step == .welcome)
    }

    @Test func setupCantBeDismissedAsRecovery() {
        let conditions = Conditions()
        let flow = makeFlow(conditions)
        flow.dismissRecovery()
        #expect(flow.step == .welcome)
    }
}

@MainActor
@Suite("Onboarding flow: resuming")
struct OnboardingResumeTests {
    @Test func anInterruptedSetupResumesOnTheStepWhereItStopped() {
        let conditions = Conditions()
        let store = InMemoryOnboardingProgressStore()
        let first = makeFlow(conditions, store: store)
        first.advance()  // welcome
        first.advance()  // xAI key
        #expect(first.step == .microphone)
        #expect(store.load().current == .microphone)
        #expect(store.load().visited == [.welcome, .xaiAccount])

        // The app is killed (iOS ends it when the microphone is allowed in
        // the Settings app) and launched again.
        let second = makeFlow(conditions, store: store)
        #expect(second.mode == .setup)
        #expect(second.step == .microphone)
        #expect(!second.canGoBack)
        second.advance()
        #expect(second.step == .speechModels)
    }

    @Test func aResumedStepIsShownEvenIfItIsNowDone() {
        // The user allowed the microphone in Settings, which relaunched the
        // app: the step shows that it worked, and Continue moves on.
        let conditions = Conditions()
        let store = InMemoryOnboardingProgressStore(OnboardingProgress(visited: [.welcome], current: .microphone))
        conditions.current.microphone = .satisfied
        let flow = makeFlow(conditions, store: store)
        #expect(flow.step == .microphone)
    }

    @Test func welcomeIsNotShownAgainOnResume() {
        let conditions = Conditions()
        let store = InMemoryOnboardingProgressStore(OnboardingProgress(visited: [.welcome]))
        let flow = makeFlow(conditions, store: store)
        #expect(flow.step == .xaiAccount)
        #expect(store.load().current == nil)  // Nothing saved until a step moves.
        flow.advance()
        #expect(store.load().current == .microphone)
    }

    @Test func aFinishedSetupIsNotShownAtLaunch() {
        let conditions = Conditions()
        let store = InMemoryOnboardingProgressStore(
            OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date()))
        let flow = makeFlow(conditions, store: store)
        #expect(flow.mode == .recovery)
        #expect(!flow.isPresented)
        #expect(flow.remainingSteps.isEmpty)
    }

    @Test func restartingForgetsTheProgress() {
        let conditions = Conditions()
        let store = InMemoryOnboardingProgressStore(
            OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date()))
        let flow = makeFlow(conditions, store: store)
        flow.restart()
        #expect(flow.mode == .setup)
        #expect(flow.step == .welcome)
        #expect(store.load() == OnboardingProgress(current: .welcome))
    }
}

@MainActor
@Suite("Onboarding flow: recovery")
struct OnboardingRecoveryTests {
    private func finishedFlow(_ conditions: Conditions) -> OnboardingFlow {
        let store = InMemoryOnboardingProgressStore(
            OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date()))
        return makeFlow(conditions, store: store)
    }

    @Test func comesBackWithOnlyTheMissingRequirements() {
        let conditions = Conditions()
        conditions.current = .satisfied
        let flow = finishedFlow(conditions)
        #expect(!flow.presentRecoveryIfNeeded())

        // The key was removed on another device and the models deleted in
        // Settings; iCloud and the optional steps don't matter here.
        conditions.current.xaiAccount = .missing
        conditions.current.speechModels = .missing
        conditions.current.iCloud = .missing
        conditions.current.voiceEnrollment = .missing
        #expect(flow.presentRecoveryIfNeeded())
        #expect(flow.mode == .recovery)
        #expect(flow.remainingSteps == [.xaiAccount, .speechModels])
        #expect(walk(flow) == [.xaiAccount, .speechModels])
        #expect(!flow.isPresented)
    }

    @Test func revokedMicrophoneAccessBringsBackTheMicrophoneStep() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.microphone = .missing
        let flow = finishedFlow(conditions)
        #expect(flow.presentRecoveryIfNeeded())
        #expect(flow.step == .microphone)
    }

    @Test func unknownAndInProgressNeverBringItBack() {
        let conditions = Conditions()
        conditions.current = OnboardingPrerequisites(
            xaiAccount: .unknown, microphone: .satisfied, speechModels: .inProgress)
        let flow = finishedFlow(conditions)
        #expect(!flow.presentRecoveryIfNeeded())
        #expect(!flow.isPresented)
    }

    @Test func neverInterruptsAConversation() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.xaiAccount = .missing
        let flow = finishedFlow(conditions)
        #expect(!flow.presentRecoveryIfNeeded(isConversationRunning: true))
        #expect(!flow.isPresented)
        #expect(flow.presentRecoveryIfNeeded(isConversationRunning: false))
    }

    @Test func aPostponedRequirementIsNotAskedForAgainThisLaunch() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.xaiAccount = .missing
        let store = InMemoryOnboardingProgressStore(
            OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date()))
        let flow = makeFlow(conditions, store: store)
        #expect(flow.presentRecoveryIfNeeded())
        flow.advance()  // "Not Now": still missing.
        #expect(!flow.isPresented)
        #expect(flow.postponed == [.xaiAccount])
        #expect(!flow.presentRecoveryIfNeeded())

        // Something else going missing still shows, without the postponed
        // step.
        conditions.current.microphone = .missing
        #expect(flow.presentRecoveryIfNeeded())
        #expect(walk(flow) == [.microphone])

        // The next launch asks again.
        let relaunched = makeFlow(conditions, store: store)
        #expect(relaunched.presentRecoveryIfNeeded())
        #expect(relaunched.step == .xaiAccount)
    }

    @Test func fixingAStepDoesNotPostponeIt() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.microphone = .missing
        let flow = finishedFlow(conditions)
        flow.presentRecoveryIfNeeded()
        conditions.current.microphone = .satisfied
        flow.advance()
        #expect(flow.postponed.isEmpty)
        conditions.current.microphone = .missing
        #expect(flow.presentRecoveryIfNeeded())
    }

    @Test func dismissingPostponesEverythingMissing() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.xaiAccount = .missing
        conditions.current.microphone = .missing
        let flow = finishedFlow(conditions)
        flow.presentRecoveryIfNeeded()
        flow.dismissRecovery()
        #expect(!flow.isPresented)
        #expect(flow.postponed == [.xaiAccount, .microphone])
        #expect(!flow.presentRecoveryIfNeeded())
    }

    @Test func recoveryDoesNotTouchTheSavedProgress() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.speechModels = .missing
        let finished = OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date())
        let store = InMemoryOnboardingProgressStore(finished)
        let flow = makeFlow(conditions, store: store)
        flow.presentRecoveryIfNeeded()
        #expect(walk(flow) == [.speechModels])
        #expect(store.load() == finished)
    }

    @Test func aPresentedFlowIsLeftAlone() {
        let conditions = Conditions()
        conditions.current = .satisfied
        conditions.current.xaiAccount = .missing
        conditions.current.microphone = .missing
        let flow = finishedFlow(conditions)
        flow.presentRecoveryIfNeeded()
        flow.advance()
        #expect(flow.step == .microphone)
        // A return to the foreground mid-recovery doesn't restart it.
        #expect(flow.presentRecoveryIfNeeded())
        #expect(flow.step == .microphone)
    }
}
