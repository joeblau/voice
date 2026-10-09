import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import os

/// A practice run the lifecycle was told about (#69).
struct PracticeRunState: Sendable {
    /// The conversation the run belongs to.
    let conversationID: ConversationID
    /// Its topic, once opened.
    var topicID: UUID?
    /// The run ended (or its conversation finished).
    var isClosed = false
}

/// Practice runs as topics (#69): each run of practice mode becomes a topic
/// of its own, titled "Practice: YC interview questions", holding the
/// user's request, every question, answer and piece of feedback, and the
/// wrap-up. Its summary is the run's record (scores and notes per
/// question), written by the practice tools as the run goes.
///
/// - **Opening.** The topic starts with the user's latest utterance (their
///   request to practice), split from the topic before it, which closes and
///   is refined as usual. If nothing came before the request in that
///   topic, the topic itself becomes the run's.
/// - **During the run** the segmenter keeps scoring exchanges, but its
///   boundaries are ignored: a run of unrelated questions would otherwise
///   become a topic per question. The run's title is final and its
///   summary is never replaced by a labeler; re-segmentation leaves it
///   alone.
/// - **Closing.** After `end_practice` the topic stays current until the
///   user speaks again, so Grok's summary stays with the run; then a new
///   topic opens at that utterance. A conversation that finishes during a
///   run closes it too.
///
/// Every request returns at once: the work runs on the lifecycle's queue,
/// in order with the transcript, so a tool call never waits for labeling.
extension TopicLifecycle: PracticeRunRecording {
    public func beginPracticeRun(title: String, at date: Date) async -> UUID? {
        // The conversation as of the latest call: the queue may not have
        // started it yet.
        guard let conversationID = trackedConversation ?? live?.id, !finished.contains(conversationID) else {
            return nil
        }
        let runID = UUID()
        practiceRuns[runID] = PracticeRunState(conversationID: conversationID)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        enqueue { lifecycle in await lifecycle.openPracticeTopic(runID, title: title, at: date) }
        return runID
    }

    public func updatePracticeRun(_ runID: UUID, summary: String) async {
        enqueue { lifecycle in
            guard let topicID = lifecycle.practiceRuns[runID]?.topicID else { return }
            do {
                _ = try await lifecycle.store.applyTopicLabel(
                    topicID, title: nil, summary: summary, finalizesTitle: false)
                await lifecycle.emit(topicID) { .updated($0) }
            } catch {
                Log.topics.error(
                    "Couldn't update a practice topic's summary: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func endPracticeRun(_ runID: UUID, at date: Date) async {
        guard practiceRuns[runID] != nil else { return }
        practiceRuns[runID]?.isClosed = true
        enqueue { lifecycle in
            guard let topicID = lifecycle.practiceRuns[runID]?.topicID, let conversation = lifecycle.live,
                conversation.practiceTopicID == topicID
            else { return }
            conversation.practiceEnded = date
            Log.topics.notice("Practice run ended; its topic closes when the user speaks next")
        }
    }

    public func isPracticeRunOpen(_ runID: UUID) async -> Bool {
        guard let run = practiceRuns[runID], !run.isClosed else { return false }
        return (trackedConversation ?? live?.id) == run.conversationID && !finished.contains(run.conversationID)
    }

    /// The topic of the practice run in progress, once its topic is open.
    public var practiceTopicID: UUID? { live?.practiceTopicID }

    // MARK: Queue work

    /// Opens the run's topic (see the type's documentation).
    func openPracticeTopic(_ runID: UUID, title: String, at date: Date) async {
        guard let conversation = live, let run = practiceRuns[runID], !run.isClosed,
            run.conversationID == conversation.id
        else {
            practiceRuns[runID]?.isClosed = true
            return
        }
        let title = title.isEmpty ? "Practice" : title
        do {
            // A run that ended but whose topic is still open (waiting for the
            // user to speak) gives way to the new one.
            if conversation.practiceTopicID != nil {
                await closePracticeTopic(in: conversation, at: date)
            }
            guard let current = conversation.currentTopicID else {
                practiceRuns[runID]?.isClosed = true
                return
            }
            let snapshot = try await store.topicSnapshot(current)
            let utterances = try await store.topicUtterances(current)
            // The request: the user's latest utterance, as the lifecycle saw
            // it or, if its turn to be fed here hasn't come yet, as stored.
            let requests = [
                conversation.lastUserUtterance?.startedAt,
                utterances.last { $0.speaker == .user && !$0.isBlank && $0.startedAt <= date }?.startedAt,
            ]
            var start = date
            if let request = requests.compactMap(\.self).max(), request >= snapshot.startedAt, request <= date {
                start = request
            }
            let earlier = utterances.contains { $0.startedAt < start }
            // A provisional break before the run is kept: the run's edges
            // are drawn now, and the segmenter's view of them is ignored.
            if conversation.provisional != nil {
                if let provisional = conversation.provisional {
                    conversation.lockedTopics.insert(provisional.topicID)
                }
                conversation.provisional = nil
            }
            let topicID: UUID
            if !earlier, !conversation.practiceTopics.contains(current), start >= snapshot.startedAt {
                topicID = current
                try await store.renameTopic(current, to: title)
                Log.topics.notice("The current topic became a practice run's topic")
            } else {
                guard start > snapshot.startedAt else {
                    practiceRuns[runID]?.isClosed = true
                    return
                }
                topicID = try await store.splitTopic(current, at: start, title: title)
                try await store.renameTopic(topicID, to: title)
                conversation.currentTopicID = topicID
                conversation.topicStartUnits[topicID] =
                    conversation.lastUserUtterance.map { conversation.startUnit(of: $0.id) } ?? conversation.unitCount
                Log.topics.notice("Opened a practice run's topic")
            }
            conversation.practiceTopicID = topicID
            conversation.practiceEnded = nil
            conversation.practiceTopics.insert(topicID)
            conversation.lockedTopics.insert(topicID)
            conversation.titledTopics.insert(topicID)
            conversation.practiceFence = max(conversation.practiceFence ?? start, start)
            practiceRuns[runID]?.topicID = topicID
            await syncPipelineTitle(conversation)
            if topicID == current {
                await emit(topicID) { .updated($0) }
            } else {
                await emit(topicID) { .opened($0) }
                // The topic before the run closed at the request.
                await refine(current, in: conversation.id, finalizing: true)
            }
        } catch {
            practiceRuns[runID]?.isClosed = true
            Log.topics.error("Couldn't open a practice run's topic: \(String(describing: error), privacy: .public)")
        }
    }

    /// Closes the practice run's topic at `date`, opening a new topic there
    /// for what comes next.
    func closePracticeTopic(in conversation: LiveConversation, at date: Date) async {
        guard let topicID = conversation.practiceTopicID else { return }
        conversation.practiceTopicID = nil
        conversation.practiceEnded = nil
        conversation.practiceFence = max(conversation.practiceFence ?? date, date)
        for (runID, run) in practiceRuns where run.topicID == topicID {
            practiceRuns[runID]?.isClosed = true
        }
        guard conversation.currentTopicID == topicID else {
            // The user merged or split it meanwhile; it closed some other way.
            return
        }
        do {
            let snapshot = try await store.topicSnapshot(topicID)
            guard date > snapshot.startedAt else { return }
            let next = try await store.splitTopic(topicID, at: date, title: Topic.placeholderTitle)
            conversation.currentTopicID = next
            conversation.topicStartUnits[next] = conversation.unitCount
            await syncPipelineTitle(conversation)
            Log.topics.notice("Closed a practice run's topic")
            await emit(topicID) { .closed($0) }
            await emit(next) { .opened($0) }
        } catch {
            Log.topics.error("Couldn't close a practice run's topic: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks the runs of a finished conversation closed.
    func closePracticeRuns(of conversationID: ConversationID) {
        for (runID, run) in practiceRuns where run.conversationID == conversationID {
            practiceRuns[runID]?.isClosed = true
        }
        if let live, live.id == conversationID {
            live.practiceTopicID = nil
            live.practiceEnded = nil
        }
    }
}
