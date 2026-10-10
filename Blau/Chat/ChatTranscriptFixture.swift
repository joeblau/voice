import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import SwiftData

/// A canned conversation for previews, UI tests and the scrolling
/// performance test (#42): `count` utterances alternating between the user
/// and Grok, with replies of every length and some cut off by the user.
///
/// UI and performance tests ask for it with the launch arguments
/// `-BlauChatFixture <count>` on a `ui-test` launch. The live app never
/// seeds anything.
enum ChatTranscriptFixture {
    /// The launch argument (`UserDefaults` key) holding the row count.
    static let launchArgument = "BlauChatFixture"

    /// Every seventh reply is cut off by the user's next utterance.
    static let interruptedEvery = 7

    /// Seeds `environment`'s store when its launch arguments ask for it.
    /// Does nothing in the live app.
    @MainActor
    static func seedIfRequested(in environment: AppEnvironment, defaults: UserDefaults = .standard) async {
        guard environment.kind != .live else { return }
        let count = defaults.integer(forKey: launchArgument)
        guard count > 0 else { return }
        await seed(count: count, into: environment.persistence)
    }

    /// Writes one conversation of `count` utterances that ended `endingAt`.
    @MainActor
    static func seed(count: Int, into persistence: PersistenceController, endingAt end: Date = Date()) async {
        await persistence.start()
        guard let container = persistence.stack?.container else {
            Log.ui.error("Couldn't seed the chat fixture: no store")
            return
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let lines = lines(count: count, endingAt: end)
        let conversation = Conversation(startedAt: lines.first?.startedAt ?? end, endedAt: end, title: "Fixture")
        context.insert(conversation)
        for line in lines {
            context.insert(
                StoredUtterance(
                    id: line.id, conversation: conversation, role: line.role, text: line.text,
                    startedAt: line.startedAt, endedAt: line.endedAt, isFinal: true,
                    source: line.role == .agent ? .grok : .parakeet,
                    endReason: line.isInterrupted ? .interrupted : nil))
        }
        do {
            try context.save()
            Log.ui.notice("Seeded the chat fixture: \(count, privacy: .public) utterances")
        } catch {
            Log.ui.error("Couldn't seed the chat fixture: \(String(describing: error), privacy: .public)")
        }
    }

    /// The fixture's lines, oldest first: user and Grok taking turns every
    /// 6 s, so the last one starts shortly before `end`.
    static func lines(count: Int, endingAt end: Date) -> [ChatLine] {
        let spacing: TimeInterval = 6
        let start = end.addingTimeInterval(-spacing * Double(count))
        return (0..<count).map { index in
            let startedAt = start.addingTimeInterval(spacing * Double(index))
            if index.isMultiple(of: 2) {
                let text = questions[(index / 2) % questions.count]
                return ChatLine(
                    id: UUID(), role: .user, text: text, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(2))
            }
            let reply = index / 2
            let isInterrupted = reply % interruptedEvery == interruptedEvery - 1
            let text = answers[reply % answers.count]
            // A cut reply was heard until after the next question started.
            let duration = isInterrupted ? spacing + 1 : spacing - 1
            return ChatLine(
                id: UUID(), role: .agent, text: isInterrupted ? cut(text) : text, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(duration), isInterrupted: isInterrupted)
        }
    }

    private static func cut(_ text: String) -> String {
        let words = text.split(separator: " ")
        return words.prefix(max(1, words.count / 2)).joined(separator: " ")
    }

    private static let questions = [
        "What should I focus on this week?",
        "Remind me what we decided about the launch date.",
        "Okay.",
        "Can you give me three questions a YC partner might ask about our traction, and how I should think about"
            + " answering each one without sounding rehearsed?",
        "Why?",
        "Tell me more about the second one.",
        "How long would that take if I started tomorrow morning?",
    ]

    private static let answers = [
        "Start with the launch checklist, then block two mornings for customer calls.",
        "You picked the second week of November, after the beta feedback is in.",
        "Sure.",
        "First, how fast are you growing week over week, and is it organic? Second, who are your best users and"
            + " what do they do every day? Third, what would make them stop using it? For each, lead with the"
            + " number, then the story behind it, and say what you don't know yet.",
        "Because the beta testers asked for offline mode first, and it touches everything else.",
        "The second one is about retention. Look at the cohort from August: most of them still talk to Blau every"
            + " day, which is the strongest signal you have.",
        "About a week for a first version, if you keep the scope to text only.",
    ]
}
