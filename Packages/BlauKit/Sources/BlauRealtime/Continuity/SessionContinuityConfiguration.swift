import Foundation

/// How the turn orchestrator keeps one conversation going for hours across
/// xAI's 120-minute session limit and dropped connections (#39).
///
/// - **Rollover.** A server conversation is renewed after ``rolloverAfter``
///   (110 min), at the first moment no turn is in progress, so the user
///   never hears it. A fresh client secret is minted first, while the old
///   connection still works, so the gap is one WebSocket upgrade. If a turn
///   is still running at ``rolloverDeadline`` (118 min) the rollover happens
///   anyway, before the server ends the session itself.
/// - **Resumption.** A dropped connection is reopened with
///   `?conversation_id=` so the server replays the history (xAI keeps it for
///   30 minutes of inactivity).
/// - **Reseeding.** When a connection starts a new server conversation (a
///   rollover, a resumption the server refused, a conversation idle for too
///   long), the history is rebuilt: the `session.update` carries the system
///   instructions and the ProfileBlock, then `conversation.item.create`
///   sends a note with the current topic's summary and the last
///   ``ReseedLimits/maximumExchanges`` exchanges.
public struct SessionContinuityConfiguration: Sendable, Equatable {
    /// What a reseed sends.
    public struct ReseedLimits: Sendable, Equatable {
        /// Exchanges (a user utterance and the replies to it) replayed, the
        /// most recent ones.
        public var maximumExchanges: Int
        /// Characters of exchange text replayed in all, newest first. Keeps
        /// the reseed cheap however long the utterances were.
        public var maximumCharacters: Int
        /// Characters of the topic summary kept.
        public var maximumSummaryCharacters: Int

        public init(maximumExchanges: Int = 8, maximumCharacters: Int = 6_000, maximumSummaryCharacters: Int = 1_500) {
            self.maximumExchanges = maximumExchanges
            self.maximumCharacters = maximumCharacters
            self.maximumSummaryCharacters = maximumSummaryCharacters
        }

        public static let standard = ReseedLimits()
    }

    /// The longest a server session may last (xAI: 120 minutes; the
    /// `max_duration` error ends it).
    public var maximumSessionDuration: Duration
    /// Session age at which the conversation is renewed between turns.
    /// `nil` turns age-based rollover off (and with it the token refresh
    /// and the deadline); a `max_duration` error still rolls over.
    public var rolloverAfter: Duration?
    /// Session age at which the rollover happens even mid-turn.
    public var rolloverDeadline: Duration
    /// How long before ``rolloverAfter`` a fresh client secret is minted, so
    /// the rollover never waits for one.
    public var tokenRefreshLead: Duration
    /// When a rollover can't get a client secret (offline, an account
    /// problem), the old session is kept and the rollover tried again after
    /// this long, until the deadline.
    public var rolloverRetryInterval: Duration
    /// Asks the server to keep the conversation for resumption
    /// (`session.resumption.enabled`).
    public var resumption: Bool
    /// A conversation idle longer than this isn't resumed: xAI drops the
    /// history after 30 minutes without activity, so the connection starts
    /// fresh and reseeds instead.
    public var resumptionIdleLimit: Duration
    /// How long a resumed connection may take to show it resumed (the
    /// replayed history, then `session.updated`) before it is treated as a
    /// new conversation and reseeded.
    public var resumeConfirmationTimeout: Duration
    /// Whether the age-based rollover resumes the same server conversation
    /// (`?conversation_id=`) instead of starting a new one and reseeding.
    /// Off: xAI documents the limit as the maximum *conversation* duration
    /// and doesn't say that resuming resets it, so a resumed conversation
    /// could still be ended at 120 minutes. Turn it on once a device test
    /// shows that resuming restarts the clock.
    public var resumesAtRollover: Bool
    public var reseed: ReseedLimits

    public init(
        maximumSessionDuration: Duration = .seconds(120 * 60),
        rolloverAfter: Duration? = .seconds(110 * 60),
        rolloverDeadline: Duration = .seconds(118 * 60),
        tokenRefreshLead: Duration = .seconds(120),
        rolloverRetryInterval: Duration = .seconds(60),
        resumption: Bool = true,
        resumptionIdleLimit: Duration = .seconds(25 * 60),
        resumeConfirmationTimeout: Duration = .seconds(5),
        resumesAtRollover: Bool = false,
        reseed: ReseedLimits = .standard
    ) {
        self.maximumSessionDuration = maximumSessionDuration
        self.rolloverAfter = rolloverAfter
        self.rolloverDeadline = rolloverDeadline
        self.tokenRefreshLead = tokenRefreshLead
        self.rolloverRetryInterval = rolloverRetryInterval
        self.resumption = resumption
        self.resumptionIdleLimit = resumptionIdleLimit
        self.resumeConfirmationTimeout = resumeConfirmationTimeout
        self.resumesAtRollover = resumesAtRollover
        self.reseed = reseed
    }

    public static let standard = SessionContinuityConfiguration()
}

/// Where the conversation's realtime session stands, for the UI ("reconnecting…")
/// and the HUD. Part of ``TurnSnapshot``.
public struct RealtimeSessionContinuity: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        /// No conversation is running.
        case idle
        /// Opening the conversation's first session.
        case connecting
        /// A session is ready: utterances go straight to Grok.
        case live
        /// Reconnected with `?conversation_id=`, waiting for the server to
        /// replay the history.
        case resuming
        /// Renewing the session before the 120-minute limit.
        case rollingOver
        /// The connection dropped and is being reopened.
        case reconnecting
    }

    public var phase: Phase
    /// How long the current server session has lasted, in whole minutes.
    public var sessionAge: Duration
    /// Sessions renewed because of their age (or a `max_duration` error).
    public var rollovers: Int
    /// Connections that resumed the server conversation.
    public var resumptions: Int
    /// New server sessions that were given the history again.
    public var reseeds: Int

    public init(
        phase: Phase = .idle, sessionAge: Duration = .zero, rollovers: Int = 0, resumptions: Int = 0, reseeds: Int = 0
    ) {
        self.phase = phase
        self.sessionAge = sessionAge
        self.rollovers = rollovers
        self.resumptions = resumptions
        self.reseeds = reseeds
    }

    /// Whether to show "Reconnecting…": the session is being reopened or
    /// renewed. What the user says meanwhile is transcribed and queued.
    public var isReconnecting: Bool {
        switch phase {
        case .resuming, .rollingOver, .reconnecting: true
        case .idle, .connecting, .live: false
        }
    }
}
