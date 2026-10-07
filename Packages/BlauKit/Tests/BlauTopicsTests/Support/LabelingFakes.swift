import BlauCore
import BlauTelemetry
import BlauTopics
import Foundation
import Synchronization

/// A labeler that answers from a closure and records every request.
final class ScriptedLabeler: TopicLabeler {
    let source: TopicLabelSource
    private let available: Mutex<Bool>
    private let handler: @Sendable (TopicLabelRequest) async throws -> TopicShift
    private let recorded = Mutex<[TopicLabelRequest]>([])

    init(
        _ source: TopicLabelSource = .foundationModels,
        available: Bool = true,
        handler: @escaping @Sendable (TopicLabelRequest) async throws -> TopicShift
    ) {
        self.source = source
        self.available = Mutex(available)
        self.handler = handler
    }

    /// Always answers with `shift`.
    convenience init(_ source: TopicLabelSource = .foundationModels, available: Bool = true, answer shift: TopicShift) {
        self.init(source, available: available) { _ in shift }
    }

    var requests: [TopicLabelRequest] { recorded.withLock { $0 } }

    func setAvailable(_ value: Bool) { available.withLock { $0 = value } }

    func isAvailable() async -> Bool { available.withLock { $0 } }

    func label(_ request: TopicLabelRequest) async throws -> TopicShift {
        recorded.withLock { $0.append(request) }
        return try await handler(request)
    }
}

/// A `TextGenerator` that answers from a closure and records requests.
final class FakeTextGenerator: TextGenerator {
    private let available: Bool
    private let handler: @Sendable (TextGenerationRequest) throws -> String
    private let recorded = Mutex<[TextGenerationRequest]>([])

    init(available: Bool = true, handler: @escaping @Sendable (TextGenerationRequest) throws -> String) {
        self.available = available
        self.handler = handler
    }

    var requests: [TextGenerationRequest] { recorded.withLock { $0 } }

    func isAvailable() async -> Bool { available }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        recorded.withLock { $0.append(request) }
        return try handler(request)
    }
}

struct FakeLabelerError: Error {}

/// A thermal state the test can change.
final class MutableThermalState: ThermalStateProviding {
    private let state: Mutex<ProcessInfo.ThermalState>
    init(_ state: ProcessInfo.ThermalState = .nominal) { self.state = Mutex(state) }
    var thermalState: ProcessInfo.ThermalState {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

extension TopicLabelingService {
    /// A service with the given labelers, a manual clock and signposts
    /// disabled.
    static func test(
        _ labelers: [any TopicLabeler],
        thermal: any ThermalStateProviding = FixedThermalState(.nominal),
        clock: any BlauClock = ManualClock(),
        timeout: Duration = .seconds(10),
        policy: TopicLabelingPolicy = .default,
        signposter: Signposter = .disabled(.topics)
    ) -> TopicLabelingService {
        TopicLabelingService(
            labelers: labelers, policy: policy, thermal: thermal, clock: clock, timeout: timeout,
            signposter: signposter)
    }
}

/// Every title a model might plausibly produce when it ignores the guide.
let unrulyTitles: [String] = [
    "A Detailed Discussion About Baking Sourdough Bread At Home This Weekend",
    "\"Sourdough Baking\"",
    "Title: marathon training plan",
    "**Refinancing the Mortgage**",
    "kubernetes deployment crashes in production clusters and how to fix them.",
    "Topic - Birthday Party Planning For Seven Year Olds",
    "Sourdough Baking.\nThe user asked about flour and proofing.",
    "the history of the roman empire and its fall",
    "iOS app store review guidelines for YC startups",
    "  marathon   training  ",
    "Planning — a — party",
    "U.S. Tax Filing Deadlines",
]
