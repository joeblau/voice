import BlauCore
import BlauPersistence
import BlauRealtime
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
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        MainScreenScaffold(audio: environment.audio)
    }
}

/// The navigation stack, its toolbars and the sheets they present. Separate
/// from `RootView` so it can own the `RecordingController` built from the
/// environment's audio service.
struct MainScreenScaffold: View {
    @Environment(ModelManager.self) private var models
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var recording: RecordingController
    @State private var isShowingSettings = false
    @State private var isShowingKeyOnboarding = false

    init(audio: any AudioService) {
        // Evaluated on every init but only kept the first time; building a
        // controller has no side effects.
        _recording = State(initialValue: RecordingController(audio: audio))
    }

    var body: some View {
        NavigationStack {
            MainScreen(onConnectAccount: { isShowingKeyOnboarding = true })
                #if DEBUG
                    // Triple-tap anywhere on the main screen to show or hide the
                    // performance HUD (#71).
                    .simultaneousGesture(
                        TapGesture(count: 3).onEnded { environment.performanceHUD.toggleVisible() })
                #endif
                // Shown only while the device is hot or short on power (#75).
                // An inset, not an overlay, so the conversation scrolls
                // beneath it like it does beneath the bars.
                .safeAreaInset(edge: .top, spacing: 0) { PerformanceIndicator() }
                .toolbar {
                    #if DEBUG
                        ToolbarItem(placement: .topBarTrailing) {
                            DebugMenuButton()
                        }
                    #endif
                    ToolbarItem(placement: .bottomBar) {
                        SettingsButton { isShowingSettings = true }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        RecordButton(phase: recording.phase) {
                            Task { await recording.toggle() }
                        }
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
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.default, value: models.isReady)
        }
        // Over the whole stack, bars included, so it can be dragged anywhere.
        .performanceHUD()
        .task {
            await recording.synchronize()
        }
        // Capture can stop without the button: the Live Activity's Stop
        // (`AppEnvironment.stopConversation()`) or an audio interruption
        // (`AudioSessionKeeper` is then not `.live`). Both happen while Blau is
        // in the background or inactive, so re-read the audio on every return
        // to the foreground. Observing the keeper's status directly is #41.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await recording.synchronize() }
            }
        }
        .alert(
            recording.failure?.title ?? "",
            isPresented: Binding(
                get: { recording.failure != nil },
                set: { if !$0 { recording.failure = nil } }
            ),
            presenting: recording.failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isShowingKeyOnboarding) {
            XAIKeyOnboardingStep {
                isShowingKeyOnboarding = false
            }
        }
    }
}

/// The main screen's content: the conversation (#42), and later the topic
/// timeline (#56). It shows the running conversation, or else the most
/// recent one; before there is any, the brand lockup and, while no usable xAI
/// key is stored, the onboarding button.
///
/// Either way it is a scroll view that runs under the bottom bar's glass,
/// anchored to the bottom like a conversation. The empty state is at least as
/// tall as the area between the bars so it stays centered, and scrolls instead
/// of clipping when Dynamic Type makes it taller than the screen.
struct MainScreen: View {
    /// Opens the xAI key onboarding step.
    var onConnectAccount: () -> Void = {}

    @Environment(XAIAccount.self) private var account
    @Environment(AppEnvironment.self) private var environment
    @Query(ChatTranscript.latestConversation) private var latestConversation: [Conversation]

    var body: some View {
        if let conversationID = environment.chat.conversationID?.rawValue ?? latestConversation.first?.id {
            ChatTranscriptView(conversationID: conversationID, onConnectAccount: onConnectAccount)
                .accessibilityIdentifier(MainScreenAccessibility.content)
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
