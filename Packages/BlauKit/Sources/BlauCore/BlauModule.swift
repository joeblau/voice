/// A BlauKit module's public marker.
///
/// Every BlauKit library exports exactly one conforming type named
/// `<Module>Module` (for example `BlauAudioModule`). The app lists them in its
/// composition root, which both proves that each library is linked and gives
/// diagnostics a single place to enumerate the subsystems.
public protocol BlauModule: Sendable {
    /// The Swift module name, for example `"BlauAudio"`.
    static var name: String { get }

    /// One line describing what the module owns.
    static var summary: String { get }
}

extension BlauModule {
    /// Derived from the runtime type name (`"BlauAudio.BlauAudioModule"`), so it
    /// always matches the module the marker is compiled into.
    public static var name: String {
        let qualified = String(reflecting: Self.self)
        guard let dot = qualified.firstIndex(of: ".") else { return qualified }
        return String(qualified[..<dot])
    }
}

/// BlauCore: shared value types, protocols and the clock abstraction. It has no
/// dependencies, and every other BlauKit module may import it.
public enum BlauCoreModule: BlauModule {
    public static let summary = "Shared value types, protocols and the clock abstraction"
}
