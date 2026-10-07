import BlauCore
import Foundation
import Security
import Synchronization

@testable import BlauRealtime

// MARK: - Keys

enum TestKeys {
    /// Assembled at runtime so the repository never contains a key-shaped
    /// literal (scripts/check-embedded-secrets.sh looks for them).
    static let primaryRaw = "xai-" + String(repeating: "Fake0Key", count: 6) + "a1b2"
    static let secondaryRaw = "xai-" + String(repeating: "Other9Key", count: 6) + "z9y8"

    static var primary: XAIAPIKey { try! XAIAPIKey(validating: primaryRaw) }
    static var secondary: XAIAPIKey { try! XAIAPIKey(validating: secondaryRaw) }
}

// MARK: - Keychain

/// An in-memory stand-in for the `SecItem` API that matches items the way
/// the Keychain does for the attributes `KeychainAPIKeyStore` uses, and
/// records every call.
final class FakeKeychain: KeychainServices {
    enum Synchronizable: Equatable, Sendable {
        case yes, no, any, unspecified
    }

    /// A `Sendable` snapshot of one call's dictionary.
    struct Call: Equatable, Sendable {
        var operation: String
        var itemClass: String?
        var service: String?
        var account: String?
        var synchronizable: Synchronizable
        var accessible: String?
        var usesDataProtectionKeychain: Bool?
        var returnsData: Bool?
        var value: Data?
        var label: String?
        var accessGroup: String?
    }

    private struct ItemID: Hashable {
        var service: String
        var account: String
        var synchronizable: Bool
    }

    private struct State {
        var items: [ItemID: Data] = [:]
        var calls: [Call] = []
        /// Status codes returned instead of performing the next calls.
        var forcedStatuses: [String: OSStatus] = [:]
        /// Inserted just before the next add, to simulate a sync race.
        var itemAppearingBeforeAdd: (service: String, account: String, data: Data)?
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }

    func force(_ status: OSStatus, for operation: String) {
        state.withLock { $0.forcedStatuses[operation] = status }
    }

    func insert(service: String, account: String, synchronizable: Bool, data: Data) {
        state.withLock {
            $0.items[ItemID(service: service, account: account, synchronizable: synchronizable)] = data
        }
    }

    func insertBeforeNextAdd(service: String, account: String, data: Data) {
        state.withLock { $0.itemAppearingBeforeAdd = (service, account, data) }
    }

    func data(service: String, account: String, synchronizable: Bool) -> Data? {
        state.withLock {
            $0.items[ItemID(service: service, account: account, synchronizable: synchronizable)]
        }
    }

    var itemCount: Int { state.withLock { $0.items.count } }

    // MARK: KeychainServices

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let call = Self.snapshot("copyMatching", query)
        return state.withLock { state in
            state.calls.append(call)
            if let forced = state.forcedStatuses.removeValue(forKey: call.operation) { return (forced, nil) }
            guard let data = state.items.first(where: { Self.matches($0.key, call) })?.value else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let call = Self.snapshot("add", attributes)
        return state.withLock { state in
            state.calls.append(call)
            if let forced = state.forcedStatuses.removeValue(forKey: call.operation) { return forced }
            if let racing = state.itemAppearingBeforeAdd {
                state.itemAppearingBeforeAdd = nil
                state.items[ItemID(service: racing.service, account: racing.account, synchronizable: true)] =
                    racing.data
            }
            let id = ItemID(
                service: call.service ?? "", account: call.account ?? "", synchronizable: call.synchronizable == .yes)
            guard state.items[id] == nil else { return errSecDuplicateItem }
            state.items[id] = call.value ?? Data()
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus {
        var call = Self.snapshot("update", query)
        let changes = Self.snapshot("update", attributesToUpdate)
        call.value = changes.value
        call.accessible = changes.accessible
        call.label = changes.label
        return state.withLock { state in
            state.calls.append(call)
            if let forced = state.forcedStatuses.removeValue(forKey: call.operation) { return forced }
            let ids = state.items.keys.filter { Self.matches($0, call) }
            guard !ids.isEmpty else { return errSecItemNotFound }
            for id in ids {
                state.items[id] = call.value ?? state.items[id]
            }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let call = Self.snapshot("delete", query)
        return state.withLock { state in
            state.calls.append(call)
            if let forced = state.forcedStatuses.removeValue(forKey: call.operation) { return forced }
            let ids = state.items.keys.filter { Self.matches($0, call) }
            guard !ids.isEmpty else { return errSecItemNotFound }
            for id in ids {
                state.items[id] = nil
            }
            return errSecSuccess
        }
    }

    // MARK: Helpers

    private static func matches(_ id: ItemID, _ call: Call) -> Bool {
        guard id.service == call.service, id.account == call.account else { return false }
        switch call.synchronizable {
        case .any: return true
        case .yes: return id.synchronizable
        case .no, .unspecified: return !id.synchronizable  // SecItem defaults to non-synced items.
        }
    }

    private static func snapshot(_ operation: String, _ query: [String: Any]) -> Call {
        let sync: Synchronizable
        switch query[kSecAttrSynchronizable as String] {
        case let value as String where value == kSecAttrSynchronizableAny as String: sync = .any
        case let value as Bool: sync = value ? .yes : .no
        case nil: sync = .unspecified
        default: sync = .unspecified
        }
        return Call(
            operation: operation,
            itemClass: query[kSecClass as String] as? String,
            service: query[kSecAttrService as String] as? String,
            account: query[kSecAttrAccount as String] as? String,
            synchronizable: sync,
            accessible: query[kSecAttrAccessible as String] as? String,
            usesDataProtectionKeychain: query[kSecUseDataProtectionKeychain as String] as? Bool,
            returnsData: query[kSecReturnData as String] as? Bool,
            value: query[kSecValueData as String] as? Data,
            label: query[kSecAttrLabel as String] as? String,
            accessGroup: query[kSecAttrAccessGroup as String] as? String
        )
    }
}

/// A store whose every call fails with `error`.
struct FailingAPIKeyStore: APIKeyStore {
    var error: APIKeyStoreError

    func load() async throws(APIKeyStoreError) -> XAIAPIKey? { throw error }
    func save(_ key: XAIAPIKey) async throws(APIKeyStoreError) { throw error }
    func delete() async throws(APIKeyStoreError) { throw error }
}

// MARK: - HTTP

/// Answers requests from a handler and records them. No network.
final class ScriptedTransport: HTTPTransport {
    enum Reply: Sendable {
        case http(status: Int, body: String, headers: [String: String] = [:])
        case failure(URLError.Code)

        static func json(_ status: Int = 200, _ body: String) -> Reply {
            .http(status: status, body: body, headers: ["Content-Type": "application/json"])
        }
    }

    private let handler: @Sendable (URLRequest) -> Reply
    private let recorded = Mutex<[URLRequest]>([])

    init(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
    }

    /// Replies by request path; unknown paths get a 404.
    convenience init(routes: [String: Reply]) {
        self.init { request in routes[request.url?.path ?? ""] ?? .json(404, #"{"error":"not found"}"#) }
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        switch handler(request) {
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        case .failure(let code):
            throw URLError(code)
        }
    }
}

extension XAIHTTPClient {
    static func test(
        store: any APIKeyStore = InMemoryAPIKeyStore(key: TestKeys.primary),
        transport: any HTTPTransport
    ) -> XAIHTTPClient {
        XAIHTTPClient(baseURL: URL(string: "https://api.x.ai")!, keyStore: store, transport: transport)
    }
}

// MARK: - Minting

/// Mints `secret-1`, `secret-2`, … or fails as scripted. Each mint first
/// sleeps `latency` on the test's clock, so tests control when it finishes.
final class FakeMinter: RealtimeClientSecretMinting {
    private struct State {
        var calls = 0
        var lifetimes: [Duration] = []
        /// Outcomes for upcoming calls; `nil` entries (or an empty script)
        /// succeed.
        var script: [XAIError?] = []
        var serverLifetime: Duration?
    }

    private let state = Mutex(State())
    private let clock: ManualClock
    private let latency: Duration

    init(clock: ManualClock, latency: Duration = .zero, script: [XAIError?] = []) {
        self.clock = clock
        self.latency = latency
        state.withLock { $0.script = script }
    }

    var calls: Int { state.withLock { $0.calls } }
    var lifetimes: [Duration] { state.withLock { $0.lifetimes } }

    func enqueue(_ outcomes: [XAIError?]) {
        state.withLock { $0.script.append(contentsOf: outcomes) }
    }

    /// Makes minted secrets report `expires_at = now + lifetime`.
    func reportServerLifetime(_ lifetime: Duration?) {
        state.withLock { $0.serverLifetime = lifetime }
    }

    func mintClientSecret(lifetime: Duration) async throws(XAIError) -> RealtimeClientSecret {
        let (call, outcome, serverLifetime) = state.withLock { state in
            state.calls += 1
            state.lifetimes.append(lifetime)
            let outcome = state.script.isEmpty ? nil : state.script.removeFirst()
            return (state.calls, outcome, state.serverLifetime)
        }
        if latency > .zero {
            do {
                try await clock.sleep(for: latency)
            } catch {
                throw .cancelled
            }
        }
        if let outcome { throw outcome }
        return RealtimeClientSecret(
            value: "secret-\(call)",
            expiresAt: serverLifetime.map { clock.now.addingTimeInterval($0.timeInterval) })
    }

    /// Yields until at least `count` mints have started.
    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }
}

// MARK: - Validation

final class FakeValidator: XAIKeyValidating {
    private let outcome: Mutex<Result<XAIKeyStatus, XAIError>>
    private let validated = Mutex<[XAIAPIKey]>([])

    init(_ outcome: Result<XAIKeyStatus, XAIError> = .success(XAIKeyStatus(name: "blau-dev"))) {
        self.outcome = Mutex(outcome)
    }

    var validatedKeys: [XAIAPIKey] { validated.withLock { $0 } }

    func setOutcome(_ newOutcome: Result<XAIKeyStatus, XAIError>) {
        outcome.withLock { $0 = newOutcome }
    }

    func validate(_ key: XAIAPIKey) async throws(XAIError) -> XAIKeyStatus {
        validated.withLock { $0.append(key) }
        return try outcome.withLock { $0 }.get()
    }
}

/// Counts calls to a `@Sendable` callback.
final class CallCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

final class InMemorySeedMarker: DevelopmentKeySeedMarker {
    private let seeded: Mutex<Bool>
    init(seeded: Bool = false) { self.seeded = Mutex(seeded) }
    var hasSeeded: Bool { seeded.withLock { $0 } }
    func markSeeded() { seeded.withLock { $0 = true } }
}
