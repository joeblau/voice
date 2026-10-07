import BlauTelemetry
import Foundation

/// Reports the device's thermal state. Production reads `ProcessInfo`;
/// tests and the thermal policy (#75) supply their own.
public protocol ThermalStateProviding: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
}

/// `ProcessInfo.processInfo.thermalState`.
public struct SystemThermalState: ThermalStateProviding {
    public init() {}
    public var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

/// A fixed thermal state, for tests and previews.
public struct FixedThermalState: ThermalStateProviding {
    public var thermalState: ProcessInfo.ThermalState
    public init(_ thermalState: ProcessInfo.ThermalState) { self.thermalState = thermalState }
}

/// How much language-model work topic labeling may do, from the most to
/// the least: `<` reads "does more work than".
public enum TopicLabelingMode: String, CaseIterable, Comparable, Hashable, Sendable {
    /// Candidates are confirmed or vetoed by a language model, and topics
    /// are titled by one.
    case full
    /// Only strong candidates (`TopicLabelingPolicy.isStrong(_:)`) are sent
    /// to a model; weaker ones are left to the segmenter's hysteresis, which
    /// drops most of them anyway. Confirmed topics are still titled by a
    /// model. The thermal and power policy's `reduced` level (#75).
    case confirmStrongCandidates
    /// Candidates aren't sent to a model (the segmenter's decision stands);
    /// a confirmed topic is still titled by one. Confirmation runs for every
    /// candidate, including ones the segmenter later drops, while titling
    /// runs once per topic, so this sheds most of the work.
    case skipConfirmation
    /// No model at all: keyword titles only.
    case keywordsOnly

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// When to spend on-device (or cloud) inference on topics.
///
/// The default follows issue #53: skip the confirm step from `.serious`, and
/// stop using language models entirely at `.critical`. The thermal and
/// power policy (#75) tightens it further: only strong candidates are
/// confirmed at `reduced` and none at `minimal` (`mode(for:level:)` takes
/// the stricter of the two).
public struct TopicLabelingPolicy: Hashable, Sendable {
    /// Confirmation is skipped at this thermal state and hotter.
    public var skipConfirmationAt: ProcessInfo.ThermalState

    /// Only keyword labels at this thermal state and hotter.
    public var keywordsOnlyAt: ProcessInfo.ThermalState

    /// A candidate the user announced ("let's switch gears") isn't vetoed:
    /// the model's "same topic" is ignored for it, though its title is used.
    public var explicitCueOverridesVeto: Bool

    /// Units around a boundary sent to the model (about half after it).
    public var contextUnits: Int

    /// In `.confirmStrongCandidates` mode, a candidate whose score is at
    /// least this multiple of the entry threshold is strong enough to send
    /// to the model.
    public var strongCandidateRatio: Double

    public init(
        skipConfirmationAt: ProcessInfo.ThermalState = .serious,
        keywordsOnlyAt: ProcessInfo.ThermalState = .critical,
        explicitCueOverridesVeto: Bool = true,
        contextUnits: Int = 6,
        strongCandidateRatio: Double = 1.5
    ) {
        self.skipConfirmationAt = skipConfirmationAt
        self.keywordsOnlyAt = keywordsOnlyAt
        self.explicitCueOverridesVeto = explicitCueOverridesVeto
        self.contextUnits = contextUnits
        self.strongCandidateRatio = strongCandidateRatio
    }

    public static let `default` = TopicLabelingPolicy()

    /// The mode for `state`.
    public func mode(for state: ProcessInfo.ThermalState) -> TopicLabelingMode {
        if state.rawValue >= keywordsOnlyAt.rawValue { return .keywordsOnly }
        if state.rawValue >= skipConfirmationAt.rawValue { return .skipConfirmation }
        return .full
    }

    /// The mode the thermal and power policy's `level` allows (#75):
    /// everything at `normal`, strong candidates only at `reduced`, titles
    /// only at `minimal`.
    public func mode(for level: PerformanceLevel) -> TopicLabelingMode {
        switch level {
        case .normal: .full
        case .reduced: .confirmStrongCandidates
        case .minimal: .skipConfirmation
        }
    }

    /// The stricter of what `state` and `level` allow.
    public func mode(for state: ProcessInfo.ThermalState, level: PerformanceLevel) -> TopicLabelingMode {
        max(mode(for: state), mode(for: level))
    }

    /// Whether `boundary` is strong enough to confirm in
    /// `.confirmStrongCandidates` mode: its score is at least
    /// `strongCandidateRatio` times the threshold it cleared.
    public func isStrong(_ boundary: TopicBoundary) -> Bool {
        boundary.score >= boundary.threshold * strongCandidateRatio
    }

    /// Whether a candidate goes to the model in `mode`.
    public func confirms(_ boundary: TopicBoundary, in mode: TopicLabelingMode) -> Bool {
        switch mode {
        case .full: true
        case .confirmStrongCandidates: isStrong(boundary)
        case .skipConfirmation, .keywordsOnly: false
        }
    }
}
