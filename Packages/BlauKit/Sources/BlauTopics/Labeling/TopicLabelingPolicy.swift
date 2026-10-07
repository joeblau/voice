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

/// How much language-model work topic labeling may do.
public enum TopicLabelingMode: String, Hashable, Sendable {
    /// Candidates are confirmed or vetoed by a language model, and topics
    /// are titled by one.
    case full
    /// Candidates aren't sent to a model (the segmenter's decision stands);
    /// a confirmed topic is still titled by one. Confirmation runs for every
    /// candidate, including ones the segmenter later drops, while titling
    /// runs once per topic, so this sheds most of the work.
    case skipConfirmation
    /// No model at all: keyword titles only.
    case keywordsOnly
}

/// When to spend on-device (or cloud) inference on topics.
///
/// The default follows issue #53: skip the confirm step from `.serious`, and
/// stop using language models entirely at `.critical`. The performance
/// policy (#75) can tighten this further.
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

    public init(
        skipConfirmationAt: ProcessInfo.ThermalState = .serious,
        keywordsOnlyAt: ProcessInfo.ThermalState = .critical,
        explicitCueOverridesVeto: Bool = true,
        contextUnits: Int = 6
    ) {
        self.skipConfirmationAt = skipConfirmationAt
        self.keywordsOnlyAt = keywordsOnlyAt
        self.explicitCueOverridesVeto = explicitCueOverridesVeto
        self.contextUnits = contextUnits
    }

    public static let `default` = TopicLabelingPolicy()

    /// The mode for `state`.
    public func mode(for state: ProcessInfo.ThermalState) -> TopicLabelingMode {
        if state.rawValue >= keywordsOnlyAt.rawValue { return .keywordsOnly }
        if state.rawValue >= skipConfirmationAt.rawValue { return .skipConfirmation }
        return .full
    }
}
