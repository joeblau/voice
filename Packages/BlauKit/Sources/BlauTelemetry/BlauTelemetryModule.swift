import BlauCore

/// BlauTelemetry: Logger categories, `OSSignposter` intervals, MetricKit and the performance
/// HUD model. Every other subsystem reports through it.
///
/// See docs/architecture.md for the modules it may depend on.
public enum BlauTelemetryModule: BlauModule {
    public static let summary = "Logger categories, signposts, MetricKit and the performance HUD model"
}
