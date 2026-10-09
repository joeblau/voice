import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import Foundation
import Observation
import SwiftData
import os

/// Wires practice mode (#69) for the app: Grok's practice tools
/// (BlauRealtime) over the synced collections (BlauPersistence's
/// `PracticeStore`), with each run recorded as a topic by the topic
/// lifecycle (BlauTopics). The modules are siblings, so the composition
/// root is where they meet (docs/architecture.md, rule 2).
extension PracticeTools {
    /// The coordinator the practice tools share: collections from whichever
    /// store `persistence` has open, runs recorded as topics by `topics`.
    @MainActor
    static func coordinator(persistence: PersistenceController, topics: TopicLifecycle) -> PracticeCoordinator {
        PracticeCoordinator(
            backend: DeferredPracticeStore { @MainActor [weak persistence] in persistence?.stack?.container },
            runs: topics)
    }
}

extension RealtimeToolRegistry {
    /// The registry with `tools` added after its own. A name that is taken
    /// is a programming error: it is logged and the tool left out, so the
    /// session still starts with the rest.
    func adding(_ tools: [any RealtimeFunctionTool]) -> RealtimeToolRegistry {
        var registry = self
        for tool in tools {
            do {
                try registry.register(tool)
            } catch {
                Log.realtime.fault("Couldn't register a tool: \(String(describing: error), privacy: .public)")
            }
        }
        return registry
    }
}

/// A request to practice a collection, made from the Collections screen.
struct PracticeRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The collection's name, as Grok's tools find it.
    let collectionTitle: String
}

/// Starts practice mode from the app (#69): the Collections screen's
/// "Practice with Grok" asks here; the main screen (which owns the record
/// button) closes Settings, starts a conversation if none is running, and
/// says the request to Grok as the user's turn
/// (`PracticeTools.startRequest`), exactly as if they had asked out loud.
/// The voice path needs none of this: Grok's practice tools switch modes
/// when the user says "let's practice YC questions".
@MainActor
@Observable
final class PracticeLauncher {
    /// The request waiting for the main screen, if any.
    private(set) var request: PracticeRequest?
    /// Why the latest request couldn't be sent, until dismissed.
    var failureMessage: String?

    /// Asks to practice `collectionTitle`.
    func practice(collectionTitle: String) {
        request = PracticeRequest(collectionTitle: collectionTitle)
        Log.ui.notice("Practice requested from the Collections screen")
    }

    /// Takes the waiting request, if it is `id`.
    func take(_ id: UUID) -> PracticeRequest? {
        guard let request, request.id == id else { return nil }
        self.request = nil
        return request
    }

    /// The user's turn that starts practicing `request`'s collection.
    static func utterance(for request: PracticeRequest, at date: Date) -> Utterance {
        Utterance(
            conversationID: ConversationID(), speaker: .user,
            text: PracticeTools.startRequest(collectionTitle: request.collectionTitle),
            timeRange: TimeRange(start: .zero, duration: .zero), startedAt: date,
            // Typed by the user in the app, not heard: nothing to verify.
            speakerDecision: .accept)
    }

    /// Sends `request` to Grok through `realtime` once `conversation` is
    /// running. Returns whether it was sent.
    @discardableResult
    func send(
        _ request: PracticeRequest, conversation: any ConversationSession, realtime: any RealtimeService,
        clock: any BlauClock
    ) async -> Bool {
        guard conversation.status.isRunning else {
            Log.ui.notice("Practice request dropped: no conversation is running")
            return false
        }
        do {
            try await realtime.send(Self.utterance(for: request, at: clock.now))
            Log.ui.notice("Practice request sent")
            return true
        } catch {
            Log.ui.error("Couldn't send the practice request: \(String(describing: error), privacy: .public)")
            failureMessage = String(localized: "Grok couldn't be asked to start practicing. Try saying it instead.")
            return false
        }
    }
}
