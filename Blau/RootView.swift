import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import BlauTranscription
import SwiftData
import SwiftUI

/// Top-level view hosted by the app's window: the main screen (#40).
///
/// The layout is fixed by the product: Settings bottom-left, Record
/// bottom-right. Both live in the navigation stack's bottom bar
/// (`ToolbarItem(placement: .bottomBar)`) with a flexible `ToolbarSpacer`
/// between them, so the system lays them out, gives them Liquid Glass, keeps
/// them clear of the home indicator on every iPhone size and in landscape, and
/// lets the conversation scroll under the bar. DEBUG builds add the debug menu
/// button to the top bar, and a triple-tap on the main screen that shows or
/// hides the performance HUD (#71).
///
/// It also hosts the xAI key entry points (#33): Settings and, while no usable
/// key is stored (none, or an unreadable one), the onboarding step. UI and
/// launch tests anchor on the identifiers in `MainScreenAccessibility`.
///
/// While onboarding (#44) is presented it replaces the main screen rather
/// than covering it, so it never competes with the main screen's sheets
/// (Settings, the key step) for presentation, and the main screen starts
/// fresh once setup is done.
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOnboarding = environment.onboarding.flow.isPresented
        ZStack {
            if isOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainScreenScaffold(conversation: environment.conversation)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .default, value: isOnboarding)
        #if DEBUG
            .environment(
                \.reportsChatRowFrames,
                environment.kind == .uiTest && ProcessInfo.processInfo.arguments.contains("-BlauChatGeometry"))
        #endif
    }
}

/// The navigation stack, its toolbars and the sheets they present. Separate
/// from `RootView` so it can own the `RecordButtonModel` built from the
/// environment's conversation session.
struct MainScreenScaffold: View {
    @Environment(ModelManager.self) private var models
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var record: RecordButtonModel
    @State private var isShowingSettings = false
    @State private var isShowingKeyOnboarding = false
    #if DEBUG
        @State private var isShowingDebugMenu = false
    #endif
    /// Why Continue This Topic (#58) couldn't read the topic.
    @State private var continueFailure: String?
    /// Settings zooms out of the bottom-left button.
    @Namespace private var settingsTransition

    init(conversation: any ConversationSession) {
        // Evaluated on every init but only kept the first time; building a
        // model has no side effects.
        _record = State(initialValue: RecordButtonModel(session: conversation))
    }

    var body: some View {
        NavigationStack {
            MainScreen(isRecording: record.state.isListening, onConnectAccount: { isShowingKeyOnboarding = true })
                #if DEBUG
                    // Triple-tap anywhere on the main screen to show or hide the
                    // performance HUD (#71).
                    .simultaneousGesture(
                        TapGesture(count: 3).onEnded { environment.performanceHUD.toggleVisible() })
                #endif
                // Shown only while the device is hot or short on power (#75).
                // An inset, not an overlay, so the conversation scrolls
                // beneath it like it does beneath the bars.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        PerformanceIndicator()
                        // #80: offline, reconnecting, key, audio and iCloud
                        // problems with their recovery actions.
                        IssueBannerSlot { isShowingKeyOnboarding = true }
                    }
                    .animation(.default, value: environment.issues.primary)
                }
                .toolbar {
                    #if DEBUG
                        if TopicTimelineFixture.offersRelabelControl(in: environment) {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Refine fixture titles") {
                                    TopicTimelineFixture.refineTitles(in: environment.persistence)
                                }
                                .accessibilityIdentifier(TopicTimelineFixture.relabelButtonIdentifier)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            DebugMenuButton { isShowingDebugMenu = true }
                        }
                    #endif
                    ToolbarItem(placement: .bottomBar) {
                        SettingsButton { isShowingSettings = true }
                    }
                    .matchedTransitionSource(id: SettingsView.transitionSourceID, in: settingsTransition)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        RecordButton(model: record)
                    }
                }
                // Above the bar, at the record button's end, while the user
                // talks with listening paused.
                .overlay(alignment: .bottomTrailing) {
                    if record.isMutedSpeechHintVisible {
                        MutedSpeechHint {
                            Task { await record.resumeListening() }
                        }
                        .padding()
                        .transition(Motion.slide(from: .bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: record.isMutedSpeechHintVisible)
                .onChange(of: record.isMutedSpeechHintVisible) { _, isVisible in
                    if isVisible {
                        AccessibilityNotification.Announcement("You're muted").post()
                    }
                }
                // Inside the stack, after the toolbar, so the card is inset
                // above the bottom bar instead of drawn over Settings and
                // Record while the speech models download.
                .safeAreaInset(edge: .bottom) {
                    // Hidden while checking, so an offline launch with every
                    // model installed doesn't flash the card.
                    if !models.isReady && models.setupStatus.phase != .checking {
                        SpeechModelSetupView()
                            .padding()
                            .transition(Motion.slide(from: .bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(.default, value: models.isReady)
        }
        // The timeline's Continue This Topic (#58) starts or seeds the
        // conversation through the record button's model, so the button,
        // its haptics and its failure alert behave as for a tap.
        .environment(\.continueTopic, TopicContinuationAction { topic in await continueTopic(topic) })
        .alert(
            "Couldn't Continue the Topic",
            isPresented: Binding(get: { continueFailure != nil }, set: { if !$0 { continueFailure = nil } }),
            presenting: continueFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Over the whole stack, bars included, so it can be dragged anywhere.
        .performanceHUD()
        // Follows the conversation (including what ends or starts it
        // without the button: the Live Activity's Stop, an interruption,
        // the debug Voice Loop screen) while the screen exists.
        .task {
            await record.run()
        }
        // Levels only while Blau is on screen; re-read the status on return.
        .onChange(of: scenePhase, initial: true) { _, phase in
            record.setVisible(phase == .active)
            if phase == .active {
                record.synchronize()
            }
        }
        .alert(
            "Couldn't Start the Conversation",
            isPresented: Binding(
                get: { record.startFailureMessage != nil },
                set: { if !$0 { record.startFailureMessage = nil } }
            ),
            presenting: record.startFailureMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Medium and large detents (SettingsView sets them), zooming out of
        // the Settings button.
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .navigationTransition(.zoom(sourceID: SettingsView.transitionSourceID, in: settingsTransition))
        }
        .sheet(isPresented: $isShowingKeyOnboarding) {
            XAIKeyOnboardingStep {
                isShowingKeyOnboarding = false
            }
        }
        #if DEBUG
            .sheet(isPresented: $isShowingDebugMenu) {
                DebugMenuView()
            }
        #endif
        // #69: "Practice with Grok" on a collection closes Settings, starts
        // a conversation if needed and asks Grok to drill the collection.
        .onChange(of: environment.practice.request?.id) { _, id in
            guard let id, let request = environment.practice.take(id) else { return }
            isShowingSettings = false
            Task { await startPractice(request) }
        }
        .alert(
            "Couldn't Start Practice",
            isPresented: Binding(
                get: { environment.practice.failureMessage != nil },
                set: { if !$0 { environment.practice.failureMessage = nil } }
            ),
            presenting: environment.practice.failureMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// Starts a conversation unless one is running (through the record
    /// button, so a failed start shows its usual alert), then sends the
    /// practice request as the user's turn.
    private func startPractice(_ request: PracticeRequest) async {
        if !environment.conversation.status.isRunning {
            await record.tap()
        }
        guard environment.conversation.status.isRunning else { return }
        if environment.kind != .live, !(await environment.realtime.isConnected) {
            // Previews and UI tests: the fake conversation doesn't connect
            // the fake realtime service on its own.
            try? await environment.realtime.connect()
        }
        await environment.practice.send(
            request, conversation: environment.conversation, realtime: environment.realtime,
            clock: environment.clock)
    }
}

extension MainScreenScaffold {
    /// Continue This Topic (#58): reads the topic off the main actor, then
    /// starts a conversation seeded with it (its summary and last
    /// exchanges), or hands it to the running conversation.
    fileprivate func continueTopic(_ topic: TimelineTopic) async {
        guard let container = environment.modelContainer else {
            continueFailure = String(localized: "Your conversations aren't available yet. Try again in a moment.")
            return
        }
        let seed: RealtimeContinuedTopic?
        do {
            seed = try await TopicSource.continuedTopic(topic, in: container)
        } catch {
            Log.ui.error("Couldn't read the topic to continue: \(String(describing: error), privacy: .public)")
            continueFailure = String(localized: "The topic couldn't be read. Try again.")
            return
        }
        guard let seed else {
            continueFailure = String(localized: "This topic has nothing to continue from yet.")
            return
        }
        switch await record.continueTopic(seed) {
        case .started, .continued:
            AccessibilityNotification.Announcement(String(localized: "Continuing \(topic.title)")).post()
        case .ignored:
            // Mid start or stop: the user tapped Record at the same moment.
            break
        case .failed:
            // A failed start shows the record button's own alert.
            if record.startFailureMessage == nil {
                continueFailure = String(localized: "The conversation couldn't pick up the topic. Try again.")
            }
        }
    }
}

/// The main screen's content: the topic timeline (#56), opened on the
/// current topic of the running conversation, or else of the most recent
/// one, with its transcript (#42) below its bullet. Before there is any
/// conversation, the brand lockup and, while no usable xAI key is stored,
/// the onboarding button.
///
/// Either way it is a scroll view that runs under the bottom bar's glass,
/// anchored to the bottom like a conversation. The empty state is at least as
/// tall as the area between the bars so it stays centered, and scrolls instead
/// of clipping when Dynamic Type makes it taller than the screen.
struct MainScreen: View {
    /// The current topic's dot pulses while the microphone is live.
    var isRecording = false
    /// Opens the xAI key onboarding step.
    var onConnectAccount: () -> Void = {}

    @Environment(XAIAccount.self) private var account
    @Environment(AppEnvironment.self) private var environment
    @Query(ChatTranscript.latestConversation) private var latestConversation: [Conversation]

    var body: some View {
        if let conversationID = environment.chat.conversationID?.rawValue ?? latestConversation.first?.id {
            // Its scroll view carries `MainScreenAccessibility.content`.
            TopicTimelineView(
                focusConversationID: conversationID, isRecording: isRecording, onConnectAccount: onConnectAccount)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        // The reader's size is the area between the bars (it respects the
        // safe area); the scroll view inside still runs under them.
        GeometryReader { visible in
            ScrollView {
                VStack(spacing: 24) {
                    BrandLockup()

                    if account.needsKeyEntry {
                        Button("Connect Your xAI Account", action: onConnectAccount)
                            .brandProminentButtonStyle()
                            .accessibilityIdentifier(XAIKeyIdentifiers.openOnboarding)
                    }
                }
                .multilineTextAlignment(.center)
                .padding()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(MainScreenAccessibility.emptyState)
                .frame(maxWidth: .infinity, minHeight: visible.size.height)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier(MainScreenAccessibility.content)
        }
        // The whole screen takes taps (the DEBUG triple-tap for the HUD).
        .contentShape(Rectangle())
    }
}

#Preview("Main screen") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        RootView()
    }
    .appEnvironment(environment)
    .environment(AppDiagnostics(store: nil))
    .task { await environment.speechModels.start() }
}

#Preview("Main screen, conversation") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        RootView()
    }
    .appEnvironment(environment)
    .environment(AppDiagnostics(store: nil))
    .task { await ChatTranscriptFixture.seed(count: 60, into: environment.persistence) }
}

#Preview("Main screen, largest text") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        RootView()
    }
    .appEnvironment(environment)
    .environment(AppDiagnostics(store: nil))
    .task { await environment.speechModels.start() }
    .dynamicTypeSize(.accessibility5)
}
