import BlauCore
import BlauTelemetry
import Foundation
import os

/// Keeping one conversation going for hours (#39): resuming the server
/// conversation after a drop, renewing the session before xAI's 120-minute
/// limit, and reseeding a session that starts a new server conversation.
///
/// **A connection opens.** If its URL carries `conversation_id`, it should
/// resume that server conversation: the session stays not ready (utterances
/// queue) until the server shows what happened. A `conversation.created`
/// naming another conversation means it started a new one; the replayed
/// history (`conversation.item.created`) or a `conversation.created` naming
/// the same one, followed by the answer to our `session.update`
/// (`session.updated`, which comes after the replay), means it resumed.
/// Without either by then, or within
/// ``SessionContinuityConfiguration/resumeConfirmationTimeout``, the
/// conversation is treated as new. A new conversation that isn't the
/// first gets the history again (``RealtimeReseed``) before the queued
/// utterances go out.
///
/// **Renewal.** At ``SessionContinuityConfiguration/rolloverAfter`` the
/// session is renewed at the next moment no turn is in progress: a client
/// secret is minted while the old connection still works, then
/// ``RealtimeClient/reconnect(to:)`` opens a new connection (a new server
/// conversation, reseeded, unless
/// ``SessionContinuityConfiguration/resumesAtRollover``). At
/// ``SessionContinuityConfiguration/rolloverDeadline`` it happens even
/// mid-turn, and a `max_duration` error from the server forces it at once.
extension TurnOrchestrator {
    /// Why the session is being renewed.
    enum RolloverReason: String, Sendable {
        /// It reached ``SessionContinuityConfiguration/rolloverAfter`` and no
        /// turn is in progress.
        case age
        /// It reached ``SessionContinuityConfiguration/rolloverDeadline``
        /// with a turn still in progress.
        case deadline
        /// The server ended it (`max_duration`).
        case maxDuration
    }

    /// One `conversation.item.created` a resumed connection replayed.
    struct ReplayedItem: Sendable, Equatable {
        let id: String?
        /// The message's role; `nil` for function calls and outputs.
        let role: RealtimeRole?
        let text: String

        init(_ item: RealtimeItem) {
            if case .message(let message) = item {
                id = message.id
                role = message.role
                text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                id = item.id
                role = nil
                text = ""
            }
        }
    }

    /// What the server said about which conversation a connection belongs
    /// to.
    struct ResumeEvidence: Sendable, Equatable {
        /// The id in `conversation.created`.
        var conversationID: String?
        /// The history it replayed.
        var replayed: [ReplayedItem] = []
    }

    /// A connection that reopened `expected`, waiting for the server to show
    /// whether it resumed.
    struct PendingResume: Sendable {
        let expected: String
        /// The session epoch of the connection.
        let session: UInt64
        /// Opened to renew the session (``SessionContinuityConfiguration/resumesAtRollover``).
        let isRollover: Bool
        var evidence: ResumeEvidence

        /// Whether the server showed it resumed `expected`.
        var isConfirmed: Bool {
            evidence.conversationID == expected || !evidence.replayed.isEmpty
        }
    }

    // MARK: Snapshot

    func continuitySnapshot() -> RealtimeSessionContinuity {
        var snapshot = continuityCounts
        if let sessionStartedAt {
            let minutes = (clock.uptime - sessionStartedAt).components.seconds / 60
            snapshot.sessionAge = .seconds(minutes * 60)
        }
        snapshot.phase =
            if conversationID == nil {
                .idle
            } else if isSessionReady {
                .live
            } else if pendingResume != nil {
                .resuming
            } else if isRollingOver {
                .rollingOver
            } else if !hasHadSession {
                .connecting
            } else {
                .reconnecting
            }
        return snapshot
    }

    // MARK: Lifecycle

    func resetContinuity() {
        cancelContinuityTasks()
        history.removeAll()
        serverConversationID = nil
        endpointConversationID = nil
        exhaustedConversationIDs.removeAll()
        sessionStartedAt = nil
        lastServerActivity = nil
        hasHadSession = false
        pendingResume = nil
        evidenceSinceDrop = ResumeEvidence()
        unconfirmedResumes = 0
        discardedSentTexts.removeAll()
        rolloverDue = false
        isRollingOver = false
        continuityCounts = RealtimeSessionContinuity()
        continuedTopic = nil
        continuedTopicDelivered = false
    }

    func cancelContinuityTasks() {
        rolloverTask?.cancel()
        rolloverTask = nil
        rolloverDeadlineTask?.cancel()
        rolloverDeadlineTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
    }

    // MARK: A connection opened

    /// A connection opened (its `session.update` is queued). Decides
    /// whether it resumes the server conversation or starts a new one.
    func sessionConnected(session: UInt64, url: URL?) {
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
        let evidence = evidenceSinceDrop
        evidenceSinceDrop = ResumeEvidence()
        pendingResume = nil

        guard hasHadSession, let expected = url.flatMap(RealtimeEndpoint.conversationID(in:)) else {
            startServerSession(session: session, conversation: evidence.conversationID)
            return
        }
        if let other = evidence.conversationID, other != expected {
            Log.realtime.notice(
                "The server started conversation \(other, privacy: .public) instead of resuming \(expected, privacy: .public)"
            )
            signposter.event("realtime.resumeRefused")
            startServerSession(session: session, conversation: other)
            return
        }
        if exhaustedConversationIDs.contains(expected) {
            startServerSession(session: session, conversation: evidence.conversationID)
            return
        }
        pendingResume = PendingResume(
            expected: expected, session: session, isRollover: isRollingOver, evidence: evidence)
        Log.realtime.notice("Resuming server conversation \(expected, privacy: .public)")
        scheduleResumeTimeout(session: session)
        publish()
    }

    /// The connection is a new server conversation (`conversation`, if the
    /// server has named it yet). Every one after the first is reseeded.
    private func startServerSession(session: UInt64, conversation: String?) {
        pendingResume = nil
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
        let needsReseed = hasHadSession
        hasHadSession = true
        unconfirmedResumes = 0
        // A new conversation never had the discarded items.
        discardedSentTexts.removeAll()
        serverConversationID = conversation
        setEndpointConversation(conversation)
        sessionStartedAt = clock.uptime
        rolloverDue = false
        scheduleSessionTimers()
        // A new server conversation knows nothing yet.
        continuedTopicDelivered = false
        if needsReseed {
            reseed(session: session)
        } else if continuedTopic != nil {
            deliverContinuation(session: session)
        }
        sessionReady()
    }

    /// The server session is ready: queued utterances go out.
    private func sessionReady() {
        isRollingOver = false
        isSessionReady = true
        publish()
        flushQueueIfReady()
        rolloverIfQuiet()
    }

    /// Sends the history to a new server session: the system note with the
    /// current topic, then the last exchanges. Utterances still queued are
    /// left out; they go out as a turn of their own right after.
    private func reseed(session: UInt64) {
        guard let conversationID else { return }
        let limits = configuration.continuity.reseed
        // A queued turn whose items a resumption already delivered has no
        // texts left, so its words come from the history instead.
        // Discarded utterances (#80) were never answered and the user chose
        // not to ask again: Grok doesn't get them either.
        let excluded = Set(queued.filter { !$0.texts.isEmpty }.map(\.user.id)).union(discardedUtterances)
        let entries = history.recent(
            exchanges: limits.maximumExchanges, characters: limits.maximumCharacters, excluding: excluded)
        continuityCounts.reseeds += 1
        signposter.event("realtime.reseed")
        Log.realtime.notice(
            "Reseeding the new realtime session with \(entries.count, privacy: .public) utterance(s)")
        let provider = reseedContext
        let client = client
        let epoch = epoch
        // The note names the continued topic again (#58).
        let continuing = continuedTopic
        continuedTopicDelivered = continuing != nil
        outbox.enqueue { [weak self] in
            guard epoch.current == session else { return }
            let topic = await provider.topicContext(for: conversationID)
            let events = RealtimeReseed.events(
                history: entries, topic: topic, limits: limits, continuing: continuing)
            do throws(RealtimeClientError) {
                for event in events {
                    guard epoch.current == session else { return }
                    try await client.send(event)
                }
                // The reseeded user texts are billed as text inputs too.
                await self?.countTextInputs(in: events)
            } catch {
                Log.realtime.error("Couldn't reseed the realtime session: \(error.description, privacy: .public)")
            }
        }
    }

    // MARK: Continuing an earlier topic (#58)

    /// Picks up an earlier topic in the running conversation: Grok is told
    /// about it (its summary and last exchanges) at once if the session is
    /// ready, otherwise as soon as it is, before any queued utterance. It
    /// replaces a topic continued before, and every later server session
    /// is reminded of it.
    ///
    /// - Throws: ``OrchestratorError/notRunning`` when no conversation is
    ///   running; start one with ``start(conversationID:waitsForConnection:continuing:)``.
    public func continueTopic(_ topic: RealtimeContinuedTopic) throws(OrchestratorError) {
        guard conversationID != nil else { throw .notRunning }
        guard !topic.isEmpty else { return }
        continuedTopic = topic
        continuedTopicDelivered = false
        Log.realtime.notice("Continuing topic \(topic.topicID, privacy: .public) in the running conversation")
        guard isSessionReady, pendingResume == nil else { return }
        deliverContinuation(session: epoch.current)
    }

    /// Sends ``continuedTopic`` to the server conversation of `session`: a
    /// system note with the topic and its summary, then its last exchanges.
    func deliverContinuation(session: UInt64) {
        guard let topic = continuedTopic else { return }
        let events = RealtimeContinuation.events(
            for: topic, limits: configuration.continuity.reseed, timeZone: .current)
        guard !events.isEmpty else { return }
        continuedTopicDelivered = true
        signposter.event("realtime.continueTopic")
        Log.realtime.notice(
            "Telling the realtime session about topic \(topic.topicID, privacy: .public) (\(events.count - 1, privacy: .public) utterance(s))"
        )
        let client = client
        let epoch = epoch
        outbox.enqueue { [weak self] in
            do throws(RealtimeClientError) {
                for event in events {
                    guard epoch.current == session else {
                        await self?.continuationNotDelivered(topic)
                        return
                    }
                    try await client.send(event)
                }
                await self?.countTextInputs(in: events)
            } catch {
                Log.realtime.error(
                    "Couldn't tell the realtime session about the continued topic: \(error.description, privacy: .public)"
                )
                await self?.continuationNotDelivered(topic)
            }
        }
    }

    /// `topic` didn't reach the session it was meant for: the next server
    /// session that starts or resumes is told instead.
    private func continuationNotDelivered(_ topic: RealtimeContinuedTopic) {
        guard continuedTopic == topic else { return }
        continuedTopicDelivered = false
    }

    // MARK: Resumption

    private func scheduleResumeTimeout(session: UInt64) {
        resumeTimeoutTask?.cancel()
        let clock = clock
        let timeout = configuration.continuity.resumeConfirmationTimeout
        resumeTimeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.resumeTimedOut(session: session)
        }
    }

    private func resumeTimedOut(session: UInt64) {
        guard let pending = pendingResume, pending.session == session else { return }
        Log.realtime.notice(
            "No confirmation that conversation \(pending.expected, privacy: .public) resumed within the timeout")
        settleResume(pending)
    }

    /// `conversation.created`: the server conversation the connection
    /// belongs to.
    func conversationCreated(_ id: String) {
        if var pending = pendingResume {
            guard id == pending.expected else {
                Log.realtime.notice(
                    "The server started conversation \(id, privacy: .public) instead of resuming \(pending.expected, privacy: .public)"
                )
                signposter.event("realtime.resumeRefused")
                startServerSession(session: pending.session, conversation: id)
                return
            }
            pending.evidence.conversationID = id
            pendingResume = pending
            return
        }
        guard connection == .connected else {
            // The new connection's state hasn't been handled yet.
            evidenceSinceDrop.conversationID = id
            return
        }
        guard id != serverConversationID else { return }
        Log.realtime.notice("Server conversation \(id, privacy: .public)")
        serverConversationID = id
        setEndpointConversation(id)
    }

    /// `conversation.item.created`: on a resumed connection, the history
    /// being replayed.
    func itemReplayed(_ item: RealtimeItem) {
        if var pending = pendingResume {
            pending.evidence.replayed.append(ReplayedItem(item))
            pendingResume = pending
        } else if connection != .connected {
            evidenceSinceDrop.replayed.append(ReplayedItem(item))
        }
    }

    /// `session.updated`: the server answered the connection's
    /// `session.update`, which it reads only after replaying the history.
    func sessionUpdated() {
        guard let pending = pendingResume else { return }
        settleResume(pending)
    }

    private func settleResume(_ pending: PendingResume) {
        guard pending.isConfirmed else {
            Log.realtime.notice(
                "Conversation \(pending.expected, privacy: .public) didn't resume; starting a new one")
            signposter.event("realtime.resumeRefused")
            startServerSession(session: pending.session, conversation: nil)
            return
        }
        pendingResume = nil
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
        unconfirmedResumes = 0
        serverConversationID = pending.expected
        continuityCounts.resumptions += 1
        signposter.event("realtime.resumed")
        Log.realtime.notice(
            "Resumed conversation \(pending.expected, privacy: .public) (\(pending.evidence.replayed.count, privacy: .public) item(s) replayed)"
        )
        if pending.isRollover {
            sessionStartedAt = clock.uptime
            rolloverDue = false
            scheduleSessionTimers()
        }
        deleteDiscardedReplayedItems(pending.evidence.replayed)
        skipReplayedItems(pending.evidence.replayed)
        // A topic continued while the connection was down hasn't reached
        // the resumed conversation yet.
        if continuedTopic != nil, !continuedTopicDelivered {
            deliverContinuation(session: pending.session)
        }
        sessionReady()
    }

    /// The user discarded queued turns whose items had already reached the
    /// server conversation (``discardQueued()``): the next connection
    /// starts a new conversation, reseeded without them. A connection
    /// already reopening the old one deletes them once it has resumed
    /// (``deleteDiscardedReplayedItems(_:)``).
    func discardedSent(_ texts: [String]) {
        discardedSentTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        Log.realtime.notice(
            "Discarded utterance(s) already reached the server conversation; the next connection starts a new one")
        forgetServerConversation()
    }

    /// A resumed conversation still holds the items of turns the user
    /// discarded while it was disconnected: they are deleted, with any
    /// reply the server made to them (none of it was heard), so the next
    /// response doesn't answer them.
    private func deleteDiscardedReplayedItems(_ replayed: [ReplayedItem]) {
        let discarded = discardedSentTexts
        discardedSentTexts.removeAll()
        guard !discarded.isEmpty, !replayed.isEmpty else { return }
        let userIndices = replayed.indices.filter { replayed[$0].role == .user }
        let userTexts = userIndices.map { replayed[$0].text }
        var matched = 0
        for count in stride(from: min(discarded.count, userTexts.count), through: 1, by: -1)
        where Array(userTexts.suffix(count)) == Array(discarded.prefix(count)) {
            matched = count
            break
        }
        guard matched > 0 else { return }
        let first = userIndices[userIndices.count - matched]
        let ids = replayed[first...].compactMap(\.id)
        guard !ids.isEmpty else { return }
        Log.realtime.notice(
            "Deleting \(ids.count, privacy: .public) discarded item(s) from the resumed conversation")
        send(ids.map { .conversationItemDelete(itemID: $0) }, turn: nil)
    }

    /// A turn sent again after the drop may already be in the resumed
    /// history: its user items went out before the connection dropped.
    /// Those aren't sent twice, and a reply the server made to them that
    /// never reached the user is removed from the history (none of it was
    /// heard), so the turn asks for its reply again.
    private func skipReplayedItems(_ replayed: [ReplayedItem]) {
        guard let index = queued.firstIndex(where: \.wasSent), !replayed.isEmpty else { return }
        let replayedUserTexts = replayed.filter { $0.role == .user }.map(\.text)
        let texts = queued[index].texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var delivered = 0
        for count in stride(from: texts.count, through: 1, by: -1)
        where Array(replayedUserTexts.suffix(count)) == Array(texts.prefix(count)) {
            delivered = count
            break
        }
        guard delivered > 0 else { return }
        queued[index].texts.removeFirst(delivered)
        Log.realtime.notice(
            "\(delivered, privacy: .public) queued item(s) were already in the resumed conversation; not sending them again"
        )
        guard let lastUser = replayed.lastIndex(where: { $0.role == .user }) else { return }
        let unheard = replayed[(lastUser + 1)...].compactMap { $0.role == .assistant ? $0.id : nil }
        if !unheard.isEmpty {
            send(unheard.map { .conversationItemDelete(itemID: $0) }, turn: nil)
        }
    }

    // MARK: A connection was lost

    /// The connection dropped or is being reopened.
    func sessionLost(_ state: RealtimeClient.ConnectionState) {
        resumeTimeoutTask?.cancel()
        resumeTimeoutTask = nil
        evidenceSinceDrop = ResumeEvidence()
        if pendingResume != nil {
            pendingResume = nil
            unconfirmedResumes += 1
            if unconfirmedResumes >= 2, serverConversationID != nil {
                // Connections to it keep dropping before it resumes: start
                // a new conversation next time.
                Log.realtime.notice("Resuming keeps failing; the next connection starts a new conversation")
                forgetServerConversation()
            }
        }
        if let last = lastServerActivity, serverConversationID != nil,
            clock.uptime - last > configuration.continuity.resumptionIdleLimit
        {
            Log.realtime.notice("The server conversation has been idle too long to resume")
            forgetServerConversation()
        }
        if case .disconnected = state {
            isRollingOver = false
        }
    }

    /// The client gave up reopening a conversation because the server
    /// refused the upgrade (the conversation expired or is unknown): open a
    /// new conversation instead, once.
    ///
    /// - Returns: Whether a new connection is being opened.
    func retryFreshAfterRefusedResume(_ error: RealtimeClientError) -> Bool {
        guard endpointConversationID != nil, case .handshakeFailed(let status?) = error,
            (400..<500).contains(status), status != 408, status != 429
        else { return false }
        Log.realtime.notice(
            "The server refused to reopen the conversation (HTTP \(status, privacy: .public)); starting a new one")
        signposter.event("realtime.resumeRefused")
        forgetServerConversation()
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connectAfterRefusedResume()
        }
        return true
    }

    private func connectAfterRefusedResume() async {
        guard let id = conversationID else { return }
        await endpointQueue.drain()
        guard conversationID == id else { return }
        do throws(RealtimeClientError) {
            try await client.connect()
        } catch {
            guard conversationID == id, error != .cancelled else { return }
            fail(TurnFailure(connectionError: error))
        }
    }

    /// Before a manual reconnect: a conversation idle longer than xAI keeps
    /// it isn't asked for.
    func forgetStaleServerConversation() async {
        if let last = lastServerActivity, serverConversationID != nil,
            clock.uptime - last > configuration.continuity.resumptionIdleLimit
        {
            forgetServerConversation()
        }
        await endpointQueue.drain()
    }

    func forgetServerConversation() {
        serverConversationID = nil
        setEndpointConversation(nil)
    }

    /// Points the client's later connections at `conversation` (resuming
    /// it), or at a new conversation when `nil`.
    private func setEndpointConversation(_ conversation: String?) {
        let conversation = configuration.continuity.resumption ? conversation : nil
        guard conversation != endpointConversationID, let baseEndpoint else { return }
        endpointConversationID = conversation
        let url = RealtimeEndpoint.url(baseEndpoint, conversationID: conversation)
        let client = client
        endpointQueue.enqueue {
            await client.setEndpoint(url)
        }
    }

    // MARK: Renewing the session

    /// Starts the clocks of a new server session: a client secret just
    /// before ``SessionContinuityConfiguration/rolloverAfter``, the renewal
    /// at it, and the deadline.
    private func scheduleSessionTimers() {
        rolloverTask?.cancel()
        rolloverDeadlineTask?.cancel()
        tokenRefreshTask?.cancel()
        rolloverTask = nil
        rolloverDeadlineTask = nil
        tokenRefreshTask = nil
        let continuity = configuration.continuity
        guard let after = continuity.rolloverAfter, let start = sessionStartedAt else { return }
        let clock = clock
        let now = clock.uptime
        let client = client
        let refreshAt = start + max(.zero, after - continuity.tokenRefreshLead)
        let deadlineAt = start + max(after, continuity.rolloverDeadline)

        tokenRefreshTask = Task {
            do {
                try await clock.sleep(for: max(.zero, refreshAt - now))
            } catch {
                return
            }
            Log.realtime.notice("Minting a client secret ahead of the session renewal")
            await client.prepareClientSecret()
        }
        rolloverTask = Task { [weak self] in
            do {
                try await clock.sleep(for: max(.zero, start + after - now))
            } catch {
                return
            }
            await self?.rolloverBecameDue()
        }
        rolloverDeadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(for: max(.zero, deadlineAt - now))
            } catch {
                return
            }
            await self?.rolloverDeadlineReached()
        }
    }

    private func rolloverBecameDue() {
        guard conversationID != nil else { return }
        rolloverDue = true
        Log.realtime.notice("The realtime session is due for renewal; waiting for a quiet moment")
        rolloverIfQuiet()
    }

    private func rolloverDeadlineReached() {
        guard conversationID != nil else { return }
        Log.realtime.notice("The realtime session reached its renewal deadline")
        startRollover(.deadline)
    }

    /// Renews the session if one is due and nothing is in progress: no
    /// turn, nothing queued, the session ready.
    func rolloverIfQuiet() {
        guard rolloverDue, !rolloverInProgress, isSessionReady, current == nil, queued.isEmpty,
            conversationID != nil
        else { return }
        startRollover(.age)
    }

    static func isMaxDuration(_ error: RealtimeErrorDetail) -> Bool {
        error.type == .maxDuration || error.code == RealtimeErrorType.maxDuration.rawValue
    }

    /// The server ended the session at its maximum duration: renew it now,
    /// as a new conversation.
    func maximumDurationReached() {
        Log.realtime.error("The server ended the realtime session at its maximum duration")
        if let serverConversationID {
            exhaustedConversationIDs.insert(serverConversationID)
        }
        forgetServerConversation()
        startRollover(.maxDuration)
    }

    private func startRollover(_ reason: RolloverReason) {
        guard !rolloverInProgress, conversationID != nil else { return }
        rolloverInProgress = true
        Task { [weak self] in
            await self?.rollOver(reason)
        }
    }

    /// Renews the session: mints a client secret while the old connection
    /// still works, then closes it and opens a new one. Utterances from the
    /// moment the old session is closed are queued for the new one.
    private func rollOver(_ reason: RolloverReason) async {
        guard let id = conversationID, let baseEndpoint else {
            rolloverInProgress = false
            return
        }
        let age = sessionStartedAt.map { clock.uptime - $0 } ?? .zero
        Log.realtime.notice(
            "Renewing the realtime session (\(reason.rawValue, privacy: .public)) after \(Int(age.components.seconds / 60), privacy: .public) min"
        )
        let secretReady = await client.prepareClientSecret()
        guard conversationID == id else {
            rolloverInProgress = false
            return
        }
        if reason == .age {
            guard secretReady else {
                // Keep the working session; try again later, at the latest
                // at the deadline.
                rolloverInProgress = false
                scheduleRolloverRetry()
                return
            }
            guard isSessionReady, current == nil, queued.isEmpty else {
                // A turn started while the secret was minted: wait for it.
                rolloverInProgress = false
                return
            }
        }

        rolloverDue = false
        rolloverTask?.cancel()
        rolloverTask = nil
        rolloverDeadlineTask?.cancel()
        rolloverDeadlineTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        var resume: String?
        if configuration.continuity.resumesAtRollover, configuration.continuity.resumption, reason != .maxDuration,
            let serverConversationID, !exhaustedConversationIDs.contains(serverConversationID)
        {
            resume = serverConversationID
        }
        if resume == nil {
            serverConversationID = nil
        }
        endpointConversationID = resume
        isRollingOver = true
        if isSessionReady {
            isSessionReady = false
            epoch.advance()
        }
        continuityCounts.rollovers += 1
        signposter.event("realtime.rollover")
        publish()

        await endpointQueue.drain()
        guard conversationID == id else {
            // Stopped meanwhile: don't reopen a connection.
            rolloverInProgress = false
            return
        }
        do throws(RealtimeClientError) {
            try await client.reconnect(to: RealtimeEndpoint.url(baseEndpoint, conversationID: resume))
        } catch {
            Log.realtime.error("Couldn't renew the realtime session: \(error.description, privacy: .public)")
        }
        rolloverInProgress = false
        if conversationID == id {
            rolloverIfQuiet()
        }
    }

    private func scheduleRolloverRetry() {
        rolloverTask?.cancel()
        let clock = clock
        let interval = configuration.continuity.rolloverRetryInterval
        Log.realtime.notice(
            "Couldn't get a client secret for the renewal; trying again in \(interval, privacy: .public)")
        rolloverTask = Task { [weak self] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            await self?.rolloverIfQuiet()
        }
    }
}
