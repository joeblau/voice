#if canImport(MetricKit)
    import BlauTelemetry
    import Foundation
    import MetricKit
    import Synchronization
    import Testing

    /// A store that keeps payloads in memory.
    final class InMemoryDiagnosticsStore: DiagnosticsStoring {
        private let saved = Mutex<[CapturedPayload]>([])

        var payloads: [CapturedPayload] { saved.withLock { $0 } }

        func save(_ payload: CapturedPayload) throws -> DiagnosticsRecord? {
            saved.withLock { $0.append(payload) }
            return DiagnosticsRecord(
                id: FileDiagnosticsStore.recordID(for: payload.json), receivedAt: .now, summary: payload.summary)
        }

        func records() throws -> [DiagnosticsRecord] { [] }

        func rawPayload(for record: DiagnosticsRecord) throws -> Data { Data() }

        func export(context: DiagnosticsExportContext, to directory: URL) throws -> URL { directory }

        func removeAll() throws { saved.withLock { $0.removeAll() } }
    }

    /// `MXMetricPayload` and `MXDiagnosticPayload` have no public initializers,
    /// so the mapping from MetricKit types is exercised on a device (see
    /// docs/performance.md, "MetricKit and diagnostics"). These tests cover
    /// what the Mac can: the subscriber's MetricKit conformance and its
    /// handling of empty deliveries.
    @Suite("MetricKit subscriber")
    struct MetricKitSubscriberTests {
        /// The protocol's methods are optional, so a signature typo would
        /// compile and silently never be called. Check the Objective-C
        /// selectors MetricKit sends.
        @Test(arguments: ["didReceiveMetricPayloads:", "didReceiveDiagnosticPayloads:"])
        func implementsTheDeliveryCallbacks(selector: String) {
            let subscriber: any MXMetricManagerSubscriber = MetricKitSubscriber(store: InMemoryDiagnosticsStore())
            #expect(subscriber.responds(to: NSSelectorFromString(selector)))
        }

        @Test func emptyDeliveriesStoreNothing() {
            let store = InMemoryDiagnosticsStore()
            let subscriber = MetricKitSubscriber(store: store)
            subscriber.didReceive([MXMetricPayload]())
            subscriber.didReceive([MXDiagnosticPayload]())
            #expect(store.payloads.isEmpty)
        }
    }
#endif
