import Foundation
import Observation
import os

/// A problem with the user's xAI key, worded for the person fixing it.
///
/// Every problem is recoverable: the entry field keeps what was typed, and
/// the user can edit it and try again, or (for problems that don't say
/// anything about the key, such as being offline) save it anyway.
public struct XAIAccountProblem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case malformedKey
        case invalidKey
        case keyDisabled
        case noCredits
        case notPermitted
        case offline
        case rateLimited
        case serverError
        case keychainLocked
        case keychainFailure
        case unexpected
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let message: String
    /// Whether the key may be fine and the user can choose to store it
    /// without a successful check (offline, rate limited, xAI outage).
    public let canSaveAnyway: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.message == rhs.message
            && lhs.canSaveAnyway == rhs.canSaveAnyway
    }

    init(kind: Kind, title: String, message: String, canSaveAnyway: Bool = false) {
        self.kind = kind
        self.title = title
        self.message = message
        self.canSaveAnyway = canSaveAnyway
    }

    static let consoleHint = "You can manage keys and credits at console.x.ai."

    public init(_ error: XAIAPIKey.FormatError) {
        let detail =
            switch error {
            case .empty: "Paste your xAI API key."
            case .containsWhitespace:
                "The key can't contain spaces or line breaks. Copy just the key and paste it again."
            case .invalidCharacters: "The key contains characters an xAI API key never has. Copy it again."
            case .tooShort: "That's too short to be an xAI API key. Make sure you copied the whole key."
            case .tooLong: "That's too long to be an xAI API key. Copy just the key and paste it again."
            }
        self.init(kind: .malformedKey, title: "That doesn't look like an API key", message: detail)
    }

    public init(_ error: XAIError) {
        switch error {
        case .missingAPIKey:
            self.init(kind: .invalidKey, title: "No API key", message: "Enter your xAI API key. \(Self.consoleHint)")
        case .invalidAPIKey:
            self.init(
                kind: .invalidKey, title: "xAI didn't accept this key",
                message: "Check that you copied the whole key, or create a new one. \(Self.consoleHint)")
        case .keyDisabled(let reason):
            let what =
                switch reason {
                case .keyBlocked: "This API key is blocked."
                case .keyDisabled: "This API key is disabled."
                case .teamBlocked: "The xAI team that owns this key is blocked."
                }
            self.init(
                kind: .keyDisabled, title: "Key switched off",
                message: "\(what) Enable it or use another key. \(Self.consoleHint)")
        case .insufficientCredits:
            self.init(
                kind: .noCredits, title: "No xAI credits",
                message: "This key's team has no credits left or hit its spending limit. "
                    + "Add credits at console.x.ai, then try again.")
        case .permissionDenied:
            self.init(
                kind: .notPermitted, title: "Key can't use voice",
                message: "This key isn't allowed to use the realtime voice API. "
                    + "Allow it in the key's settings at console.x.ai, or use another key.")
        case .network:
            self.init(
                kind: .offline, title: "Couldn't reach xAI",
                message: "Check your internet connection and try again.", canSaveAnyway: true)
        case .rateLimited:
            self.init(
                kind: .rateLimited, title: "Too many requests",
                message: "xAI is limiting requests right now. Wait a moment and try again.", canSaveAnyway: true)
        case .server(let status, _):
            self.init(
                kind: .serverError, title: "xAI is having problems",
                message: "xAI returned an error (HTTP \(status)). Try again in a little while.", canSaveAnyway: true)
        case .keyStore(let storeError):
            self.init(storeError)
        case .badRequest, .invalidResponse, .cancelled:
            self.init(
                kind: .unexpected, title: "Couldn't check the key",
                message: "Something unexpected happened while checking the key with xAI. Try again.",
                canSaveAnyway: true)
        }
    }

    public init(_ error: APIKeyStoreError) {
        switch error {
        case .locked:
            self.init(
                kind: .keychainLocked, title: "Unlock your iPhone",
                message: "The Keychain is unavailable until you unlock your iPhone. Unlock it and try again.")
        case .corruptItem:
            self.init(
                kind: .keychainFailure, title: "Stored key is unreadable",
                message: "The key saved in your Keychain is damaged. Enter your key again to replace it.")
        case .keychain(let status):
            self.init(
                kind: .keychainFailure, title: "Keychain error",
                message: "Blau couldn't use the Keychain (error \(status)). Try again.")
        }
    }
}

/// The xAI account as the UI sees it: whether a key is stored, checking and
/// saving a new key, removing it, and the problem to show if something went
/// wrong. Settings (→ xAI account) and onboarding share one instance.
///
/// A key is stored only once xAI accepts it, so an invalid key never
/// replaces a working one. Every failure leaves the user's input in place
/// and sets ``problem``, which the UI shows next to the field.
@MainActor
@Observable
public final class XAIAccount {
    public enum Status: Sendable, Equatable {
        /// ``load()`` hasn't finished yet.
        case unknown
        /// No key is stored; features that need xAI are unavailable.
        case noKey
        /// A key is stored (on this device or synced from another one).
        case connected(ConnectedKey)
        /// The Keychain couldn't be read (for example before first unlock).
        case unavailable(APIKeyStoreError)
    }

    public struct ConnectedKey: Sendable, Equatable {
        /// The last four characters, e.g. `•••• 1a2b`.
        public var redacted: String
        /// The key's name in the xAI console, when known.
        public var name: String?
        /// Whether the key was checked with xAI in this session.
        public var verified: Bool
    }

    public enum Activity: Sendable, Equatable {
        case idle
        case loading
        case validating
        case saving
        case removing
        /// ``testConnection(now:)`` is checking the stored key with xAI.
        case testing
    }

    /// The outcome of the last ``testConnection(now:)`` (Settings → xAI
    /// account → Test Connection).
    public enum ConnectionCheck: Sendable, Equatable {
        /// Not tested since launch or since the key last changed.
        case notTested
        /// A test is running.
        case testing
        /// xAI accepted the stored key at `at`. `realtimeVerified` is
        /// `false` when the realtime mint step was inconclusive (see
        /// ``XAIKeyStatus/realtimeVerified``).
        case succeeded(at: Date, realtimeVerified: Bool)
        /// The test failed; the problem says why and what to do.
        case failed(XAIAccountProblem)
    }

    public private(set) var status: Status = .unknown
    public private(set) var activity: Activity = .idle
    /// The problem to show, if any. Cleared by the next attempt or
    /// ``dismissProblem()``.
    public private(set) var problem: XAIAccountProblem?
    /// The last connection test's outcome. Reset whenever the stored key
    /// changes.
    public private(set) var connectionCheck: ConnectionCheck = .notTested

    public var hasKey: Bool {
        if case .connected = status { true } else { false }
    }

    /// Whether the UI should offer key entry (onboarding's connect button,
    /// the key field in Settings): no key is stored, or the stored one is
    /// unreadable (``APIKeyStoreError/corruptItem``). Reloading can't fix a
    /// corrupt item, but saving a new key overwrites it in place and
    /// removing the key deletes it.
    public var needsKeyEntry: Bool {
        switch status {
        case .noKey, .unavailable(.corruptItem): true
        case .unknown, .connected, .unavailable: false
        }
    }

    public var isBusy: Bool { activity != .idle }

    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "xai")

    private let store: any APIKeyStore
    private let validator: any XAIKeyValidating
    private let onKeyChange: @Sendable () async -> Void
    /// The key from the last attempt that failed for a reason unrelated to
    /// the key itself, kept in memory only for "Save anyway".
    private var unverifiedCandidate: XAIAPIKey?

    /// - Parameters:
    ///   - store: The Keychain store.
    ///   - validator: Checks keys with xAI before they are stored.
    ///   - onKeyChange: Called after the stored key changes or is removed,
    ///     e.g. to invalidate cached realtime tokens.
    public init(
        store: any APIKeyStore,
        validator: any XAIKeyValidating,
        onKeyChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.validator = validator
        self.onKeyChange = onKeyChange
    }

    /// Reads the stored key. Call on launch and whenever the app becomes
    /// active, to pick up a key that arrived from another device through
    /// iCloud Keychain (or was removed there).
    public func load() async {
        guard activity == .idle else { return }
        activity = .loading
        defer { activity = .idle }
        do {
            let key = try await store.load()
            switch (key, status) {
            case (nil, _):
                status = .noKey
            case (let key?, .connected(let current)) where current.redacted == key.redacted:
                break  // Same key; keep what we know about it.
            case (let key?, _):
                status = .connected(ConnectedKey(redacted: key.redacted, name: nil, verified: false))
            }
        } catch {
            Self.logger.error("Couldn't read the xAI key: \(String(describing: error), privacy: .public)")
            status = .unavailable(error)
        }
    }

    /// Checks `input` with xAI and stores it if it works.
    ///
    /// - Returns: `true` when the key was stored. On `false`, ``problem``
    ///   says why.
    @discardableResult
    public func connect(apiKey input: String) async -> Bool {
        guard activity == .idle else { return false }
        problem = nil
        unverifiedCandidate = nil

        let key: XAIAPIKey
        do {
            key = try XAIAPIKey(validating: input)
        } catch {
            problem = XAIAccountProblem(error)
            return false
        }

        activity = .validating
        let keyStatus: XAIKeyStatus
        do {
            keyStatus = try await validator.validate(key)
        } catch {
            activity = .idle
            Self.logger.notice("xAI key check failed: \(String(describing: error), privacy: .public)")
            let problem = XAIAccountProblem(error)
            if problem.canSaveAnyway {
                unverifiedCandidate = key
            }
            self.problem = problem
            return false
        }

        activity = .idle
        return await persist(key, name: keyStatus.name, verified: true)
    }

    /// Stores the key from the last attempt even though it couldn't be
    /// checked. Only possible when ``problem`` allows it
    /// (``XAIAccountProblem/canSaveAnyway``).
    @discardableResult
    public func saveWithoutVerifying() async -> Bool {
        guard activity == .idle, problem?.canSaveAnyway == true, let key = unverifiedCandidate else { return false }
        problem = nil
        return await persist(key, name: nil, verified: false)
    }

    /// Removes the key from the Keychain, and with it from every device
    /// that syncs through iCloud Keychain.
    public func removeKey() async {
        guard activity == .idle else { return }
        problem = nil
        activity = .removing
        defer { activity = .idle }
        do {
            try await store.delete()
            status = .noKey
            connectionCheck = .notTested
            await onKeyChange()
        } catch {
            problem = XAIAccountProblem(error)
        }
    }

    /// Checks the **stored** key with xAI again, with the same unbilled
    /// calls ``connect(apiKey:)`` makes (the key's metadata, then a
    /// throwaway realtime client secret), and records the outcome in
    /// ``connectionCheck``.
    ///
    /// The key stays stored whatever the outcome: a failure says why
    /// (offline, no credits, key switched off...) and the user decides what
    /// to do. A success also refreshes the key's name and marks it verified.
    ///
    /// - Parameter now: When the test ran, for "Checked just now".
    /// - Returns: `true` when xAI accepted the key.
    @discardableResult
    public func testConnection(now: @autoclosure () -> Date = Date()) async -> Bool {
        guard activity == .idle else { return false }
        activity = .testing
        connectionCheck = .testing
        defer { activity = .idle }

        let key: XAIAPIKey?
        do {
            key = try await store.load()
        } catch {
            status = .unavailable(error)
            connectionCheck = .failed(XAIAccountProblem(error))
            return false
        }
        guard let key else {
            status = .noKey
            connectionCheck = .notTested
            return false
        }

        let knownName: String? =
            if case .connected(let current) = status, current.redacted == key.redacted { current.name } else { nil }
        do {
            let result = try await validator.validate(key)
            status = .connected(ConnectedKey(redacted: key.redacted, name: result.name ?? knownName, verified: true))
            connectionCheck = .succeeded(at: now(), realtimeVerified: result.realtimeVerified)
            Self.logger.info("xAI connection test passed")
            return true
        } catch {
            Self.logger.notice("xAI connection test failed: \(String(describing: error), privacy: .public)")
            status = .connected(ConnectedKey(redacted: key.redacted, name: knownName, verified: false))
            connectionCheck = .failed(XAIAccountProblem(error))
            return false
        }
    }

    /// Hides the current problem.
    public func dismissProblem() {
        problem = nil
        unverifiedCandidate = nil
    }

    /// Lets the realtime layer surface a key or account problem it hit while
    /// in use (for example credits running out mid-conversation), so
    /// Settings shows it.
    public func report(_ error: XAIError) {
        guard error.requiresUserAction else { return }
        problem = XAIAccountProblem(error)
    }

    private func persist(_ key: XAIAPIKey, name: String?, verified: Bool) async -> Bool {
        activity = .saving
        defer { activity = .idle }
        do {
            try await store.save(key)
        } catch {
            problem = XAIAccountProblem(error)
            return false
        }
        unverifiedCandidate = nil
        status = .connected(ConnectedKey(redacted: key.redacted, name: name, verified: verified))
        connectionCheck = .notTested
        await onKeyChange()
        return true
    }
}
