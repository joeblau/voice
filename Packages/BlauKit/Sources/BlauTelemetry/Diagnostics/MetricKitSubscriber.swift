#if canImport(MetricKit)
    import Foundation
    import MetricKit
    import os

    /// Receives MetricKit's metric and diagnostic payloads and stores them
    /// with a `DiagnosticsStoring`.
    ///
    /// Start it once, as early as possible in the app's life:
    ///
    /// ```swift
    /// let subscriber = MetricKitSubscriber(store: store)
    /// subscriber.start()
    /// ```
    ///
    /// MetricKit delivers metric payloads (hang time, memory, launch time,
    /// exits, Blau's `mxSignpost` intervals) about once a day, and diagnostic
    /// payloads (hang, crash, CPU and disk-write exception reports) at the
    /// next launch after they happen. Payloads only arrive from real devices,
    /// including TestFlight installs, not from the Simulator; in Xcode use
    /// **Debug > Simulate MetricKit Payloads** with a device attached.
    ///
    /// This uses `MXMetricManager`, which covers Blau's iOS 26 deployment
    /// target. iOS 27 adds the Swift `MetricManager` with `Codable` reports;
    /// `MXMetricManager` keeps working there (it is marked "to be
    /// deprecated", not deprecated), so one code path serves both.
    public final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        private let store: any DiagnosticsStoring

        public init(store: any DiagnosticsStoring) {
            self.store = store
        }

        /// Subscribes to MetricKit, then stores anything MetricKit delivered
        /// before this launch subscribed (`pastPayloads`). Payloads are
        /// de-duplicated by content, so seeing one twice is harmless.
        public func start() {
            let manager = MXMetricManager.shared
            manager.add(self)
            ingest(metrics: manager.pastPayloads, source: "past")
            ingest(diagnostics: manager.pastDiagnosticPayloads, source: "past")
            Log.data.notice("MetricKit subscriber started")
        }

        /// Unsubscribes from MetricKit.
        public func stop() {
            MXMetricManager.shared.remove(self)
        }

        // MARK: MXMetricManagerSubscriber

        // MetricKit calls these on a background queue. Payloads are written
        // before returning so nothing is lost if the app is suspended.

        public func didReceive(_ payloads: [MXMetricPayload]) {
            ingest(metrics: payloads, source: "delivered")
        }

        public func didReceive(_ payloads: [MXDiagnosticPayload]) {
            ingest(diagnostics: payloads, source: "delivered")
        }

        // MARK: Ingest

        private func ingest(metrics payloads: [MXMetricPayload], source: StaticString) {
            for payload in payloads {
                persist(CapturedPayload(json: payload.jsonRepresentation(), summary: .metrics(.init(payload))), source)
            }
        }

        private func ingest(diagnostics payloads: [MXDiagnosticPayload], source: StaticString) {
            for payload in payloads {
                persist(
                    CapturedPayload(json: payload.jsonRepresentation(), summary: .diagnostics(.init(payload))),
                    source)
            }
        }

        private func persist(_ payload: CapturedPayload, _ source: StaticString) {
            let kind = payload.kind.rawValue
            let source = source.description
            do {
                if let record = try store.save(payload) {
                    Log.data.notice(
                        "Stored MetricKit \(kind, privacy: .public) payload \(record.id, privacy: .public) (\(source, privacy: .public))"
                    )
                }
            } catch {
                Log.data.error(
                    "Couldn't store MetricKit \(kind, privacy: .public) payload: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Summaries from MetricKit types

    extension PayloadEnvironment {
        init(_ metaData: MXMetaData?, appVersion: String?) {
            guard let metaData else {
                self.init(appVersion: appVersion)
                return
            }
            self.init(
                appVersion: appVersion,
                appBuild: metaData.applicationBuildVersion,
                osVersion: metaData.osVersion,
                deviceType: metaData.deviceType,
                platformArchitecture: metaData.platformArchitecture,
                isTestFlightApp: metaData.isTestFlightApp,
                isLowPowerModeEnabled: metaData.lowPowerModeEnabled
            )
        }
    }

    extension DurationHistogram {
        init(_ histogram: MXHistogram<UnitDuration>) {
            let buckets = histogram.bucketEnumerator.allObjects.compactMap { object -> Bucket? in
                guard let bucket = object as? MXHistogramBucket<UnitDuration> else { return nil }
                return Bucket(
                    start: bucket.bucketStart.converted(to: .seconds).value,
                    end: bucket.bucketEnd.converted(to: .seconds).value,
                    count: bucket.bucketCount
                )
            }
            self.init(buckets: buckets)
        }
    }

    extension AppExitCounts {
        init(_ data: MXForegroundExitData) {
            self.init(
                normal: data.cumulativeNormalAppExitCount,
                memoryResourceLimit: data.cumulativeMemoryResourceLimitExitCount,
                badAccess: data.cumulativeBadAccessExitCount,
                abnormal: data.cumulativeAbnormalExitCount,
                illegalInstruction: data.cumulativeIllegalInstructionExitCount,
                watchdog: data.cumulativeAppWatchdogExitCount
            )
        }

        init(_ data: MXBackgroundExitData) {
            self.init(
                normal: data.cumulativeNormalAppExitCount,
                memoryResourceLimit: data.cumulativeMemoryResourceLimitExitCount,
                badAccess: data.cumulativeBadAccessExitCount,
                abnormal: data.cumulativeAbnormalExitCount,
                illegalInstruction: data.cumulativeIllegalInstructionExitCount,
                watchdog: data.cumulativeAppWatchdogExitCount,
                cpuResourceLimit: data.cumulativeCPUResourceLimitExitCount,
                memoryPressure: data.cumulativeMemoryPressureExitCount,
                suspendedWithLockedFile: data.cumulativeSuspendedWithLockedFileExitCount,
                backgroundTaskAssertionTimeout: data.cumulativeBackgroundTaskAssertionTimeoutExitCount
            )
        }
    }

    extension SignpostMetricSummary {
        init(_ metric: MXSignpostMetric) {
            let data = metric.signpostIntervalData
            self.init(
                category: metric.signpostCategory,
                name: metric.signpostName,
                totalCount: metric.totalCount,
                duration: data.map { DurationHistogram($0.histogrammedSignpostDuration) },
                cumulativeCPUSeconds: data?.cumulativeCPUTime?.converted(to: .seconds).value,
                averageMemoryBytes: data?.averageMemory?.averageMeasurement.converted(to: .bytes).value,
                cumulativeLogicalWriteBytes: data?.cumulativeLogicalWrites?.converted(to: .bytes).value
            )
        }
    }

    extension MetricPayloadSummary {
        init(_ payload: MXMetricPayload) {
            let exits = payload.applicationExitMetrics
            self.init(
                periodStart: payload.timeStampBegin,
                periodEnd: payload.timeStampEnd,
                environment: PayloadEnvironment(payload.metaData, appVersion: payload.latestApplicationVersion),
                latestAppVersion: payload.latestApplicationVersion,
                includesMultipleAppVersions: payload.includesMultipleApplicationVersions,
                peakMemoryBytes: payload.memoryMetrics?.peakMemoryUsage.converted(to: .bytes).value,
                averageSuspendedMemoryBytes: payload.memoryMetrics?.averageSuspendedMemory.averageMeasurement
                    .converted(to: .bytes).value,
                cumulativeCPUSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value,
                cumulativeLogicalWriteBytes: payload.diskIOMetrics?.cumulativeLogicalWrites.converted(to: .bytes)
                    .value,
                hangTime: payload.applicationResponsivenessMetrics.map {
                    DurationHistogram($0.histogrammedApplicationHangTime)
                },
                timeToFirstDraw: payload.applicationLaunchMetrics.map {
                    DurationHistogram($0.histogrammedTimeToFirstDraw)
                },
                resumeTime: payload.applicationLaunchMetrics.map {
                    DurationHistogram($0.histogrammedApplicationResumeTime)
                },
                foregroundExits: exits.map { AppExitCounts($0.foregroundExitData) },
                backgroundExits: exits.map { AppExitCounts($0.backgroundExitData) },
                signposts: (payload.signpostMetrics ?? []).map(SignpostMetricSummary.init)
            )
        }
    }

    extension DiagnosticPayloadSummary {
        init(_ payload: MXDiagnosticPayload) {
            let hangs = payload.hangDiagnostics ?? []
            let crashes = payload.crashDiagnostics ?? []
            let cpuExceptions = payload.cpuExceptionDiagnostics ?? []
            let diskWriteExceptions = payload.diskWriteExceptionDiagnostics ?? []
            #if os(iOS)
                let launches = payload.appLaunchDiagnostics ?? []
                let slowLaunchSeconds = launches.map { $0.launchDuration.converted(to: .seconds).value }
                let launchDiagnostics: [MXDiagnostic] = launches
            #else
                let slowLaunchSeconds: [Double] = []
                let launchDiagnostics: [MXDiagnostic] = []
            #endif

            let first: MXDiagnostic? =
                hangs.first ?? crashes.first ?? cpuExceptions.first ?? diskWriteExceptions.first
                ?? launchDiagnostics.first

            self.init(
                periodStart: payload.timeStampBegin,
                periodEnd: payload.timeStampEnd,
                environment: PayloadEnvironment(first?.metaData, appVersion: first?.applicationVersion),
                hangs: hangs.map {
                    HangEvent(
                        durationSeconds: $0.hangDuration.converted(to: .seconds).value,
                        appVersion: $0.applicationVersion)
                },
                crashes: crashes.map { crash in
                    CrashEvent(
                        exceptionType: crash.exceptionType?.intValue,
                        exceptionCode: crash.exceptionCode?.int64Value,
                        signal: crash.signal?.intValue,
                        terminationReason: crash.terminationReason,
                        objectiveCExceptionName: crash.exceptionReason?.exceptionName,
                        appVersion: crash.applicationVersion
                    )
                },
                cpuExceptions: cpuExceptions.map {
                    CPUExceptionEvent(
                        totalCPUSeconds: $0.totalCPUTime.converted(to: .seconds).value,
                        totalSampledSeconds: $0.totalSampledTime.converted(to: .seconds).value
                    )
                },
                diskWriteExceptions: diskWriteExceptions.map {
                    DiskWriteExceptionEvent(totalWriteBytes: $0.totalWritesCaused.converted(to: .bytes).value)
                },
                slowLaunchSeconds: slowLaunchSeconds
            )
        }
    }
#endif
