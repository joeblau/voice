import Dispatch

/// The system's memory pressure, as `TranscriberRouter` cares about it.
public enum MemoryPressureLevel: String, CaseIterable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

/// Reports the system's memory pressure (`DispatchSource
/// .makeMemoryPressureSource`), so the composition root can tell
/// `TranscriberRouter` to move transcription to Apple's engine, whose model
/// runs outside Blau's process, before iOS terminates the app:
///
/// ```swift
/// router.followMemoryPressure(MemoryPressureMonitor.levels())
/// ```
public enum MemoryPressureMonitor {
    /// The pressure level each time it changes, until the stream is
    /// cancelled.
    public static func levels() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak source] in
                guard let event = source?.data else { return }
                if event.contains(.critical) {
                    continuation.yield(.critical)
                } else if event.contains(.warning) {
                    continuation.yield(.warning)
                } else {
                    continuation.yield(.normal)
                }
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.activate()
        }
    }
}
