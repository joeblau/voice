import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import SwiftData

/// A canned history for previews and UI tests of the topic timeline (#56):
/// `topicCount` topics over three conversations (two days ago, yesterday
/// and today), each with a few lines, the last topic still open with a
/// provisional title. Some older titles are provisional too.
///
/// UI tests ask for it with `-BlauTimelineFixture <topic count>` on a
/// `ui-test` launch, and with `-BlauTimelineRelabelAfter <seconds>` to have
/// every provisional title refined that long after seeding, the way the
/// topic lifecycle refines them from another context. The live app never
/// seeds anything.
enum TopicTimelineFixture {
    /// The launch argument (`UserDefaults` key) holding the topic count.
    static let launchArgument = "BlauTimelineFixture"
    /// The launch argument holding the delay before titles are refined.
    static let relabelArgument = "BlauTimelineRelabelAfter"
    /// Lines per topic: user and Grok taking turns.
    static let linesPerTopic = 4
    /// Every third older topic starts with a provisional title.
    static let provisionalEvery = 3

    /// The titles, in timeline order (cycled), and what each provisional
    /// title is refined to.
    static let titles = [
        "Seed Round Planning", "Hiring the First Engineer", "Japan Trip Itinerary", "Marathon Training",
        "Launch Checklist", "YC Interview Questions", "Pricing Experiments", "Offline Mode", "Customer Calls",
        "Board Update", "Sourdough Starter", "Beta Feedback",
    ]

    /// What a provisional title in the fixture reads before it is refined.
    static func provisionalTitle(for index: Int) -> String {
        "Draft \(index + 1)"
    }

    /// The refined title of topic `index`.
    static func title(for index: Int) -> String {
        titles[index % titles.count]
    }

    /// Seeds `environment`'s store when its launch arguments ask for it, and
    /// refines the titles later if asked. Does nothing in the live app.
    @MainActor
    static func seedIfRequested(in environment: AppEnvironment, defaults: UserDefaults = .standard) async {
        guard environment.kind != .live else { return }
        let count = defaults.integer(forKey: launchArgument)
        guard count > 0 else { return }
        await seed(topicCount: count, into: environment.persistence)
        let delay = defaults.double(forKey: relabelArgument)
        guard delay > 0 else { return }
        let persistence = environment.persistence
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            refineTitles(in: persistence)
        }
    }

    /// Writes the history, ending now.
    @MainActor
    static func seed(topicCount: Int, into persistence: PersistenceController, now: Date = Date()) async {
        await persistence.start()
        guard let container = persistence.stack?.container else {
            Log.ui.error("Couldn't seed the timeline fixture: no store")
            return
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Today's conversation started long enough ago to hold its topics.
        let todayTopics = max(1, topicCount - 2 * (topicCount / 3))
        let starts = [
            calendar.date(byAdding: .day, value: -2, to: today)!.addingTimeInterval(9 * 3600),
            calendar.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(18 * 3600),
            now.addingTimeInterval(-Double(todayTopics) * topicLength - 60),
        ]
        let perConversation = [topicCount / 3, topicCount / 3, todayTopics]
        var index = 0
        for (conversationIndex, start) in starts.enumerated() where perConversation[conversationIndex] > 0 {
            let isToday = conversationIndex == starts.count - 1
            let count = perConversation[conversationIndex]
            let end = start.addingTimeInterval(Double(count) * topicLength)
            let conversation = Conversation(startedAt: start, endedAt: isToday ? nil : end)
            context.insert(conversation)
            for ordinal in 0..<count {
                let topicStart = start.addingTimeInterval(Double(ordinal) * topicLength)
                let isOpen = isToday && ordinal == count - 1
                let isProvisional = isOpen || index % provisionalEvery == provisionalEvery - 1
                let topic = Topic(
                    startedAt: topicStart,
                    endedAt: isOpen ? nil : topicStart.addingTimeInterval(topicLength),
                    title: isProvisional ? provisionalTitle(for: index) : title(for: index),
                    titleIsProvisional: isProvisional,
                    summary: isOpen
                        ? nil : "Talked through \(title(for: index).lowercased()) and agreed on next steps.",
                    ordinal: ordinal)
                context.insert(topic)
                topic.conversation = conversation
                for line in lines(for: index, startingAt: topicStart) {
                    context.insert(
                        StoredUtterance(
                            id: line.id, conversation: conversation, topic: topic, role: line.role, text: line.text,
                            startedAt: line.startedAt, endedAt: line.endedAt, isFinal: true,
                            source: line.role == .agent ? .grok : .parakeet))
                }
                index += 1
            }
        }
        do {
            try context.save()
            Log.ui.notice("Seeded the timeline fixture: \(topicCount, privacy: .public) topics")
        } catch {
            Log.ui.error("Couldn't seed the timeline fixture: \(String(describing: error), privacy: .public)")
        }
    }

    /// Gives every provisional title its final one, from a context of its
    /// own, as the topic lifecycle's store does.
    @MainActor
    static func refineTitles(in persistence: PersistenceController) {
        guard let container = persistence.stack?.container else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let topics = try context.fetch(FetchDescriptor<Topic>(sortBy: [SortDescriptor(\.startedAt)]))
            for (index, topic) in topics.enumerated() where topic.titleIsProvisional {
                topic.title = title(for: index)
                topic.titleIsProvisional = false
            }
            try context.save()
            Log.ui.notice("Refined the timeline fixture's titles")
        } catch {
            Log.ui.error(
                "Couldn't refine the timeline fixture's titles: \(String(describing: error), privacy: .public)")
        }
    }

    /// How long each topic lasts.
    static let topicLength: TimeInterval = 8 * 60

    /// Topic `index`'s lines, a minute apart from `start`.
    static func lines(for index: Int, startingAt start: Date) -> [ChatLine] {
        let all = ChatTranscriptFixture.lines(
            count: linesPerTopic * (index + 1), endingAt: start.addingTimeInterval(Double(linesPerTopic) * 60))
        // The fixture's lines alternate from the user; take this topic's and
        // space them a minute apart.
        return all.suffix(linesPerTopic).enumerated().map { offset, line in
            let startedAt = start.addingTimeInterval(Double(offset) * 60 + 5)
            let length = (line.endedAt ?? line.startedAt).timeIntervalSince(line.startedAt)
            return ChatLine(
                id: UUID(), role: line.role, text: line.text, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(min(length, 50)))
        }
    }
}
