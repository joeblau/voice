#if DEBUG
    import Foundation

    /// Made-up MetricKit payloads for tests, SwiftUI previews and the Debug
    /// build's "Add sample payloads" button, so the diagnostics screen and the
    /// export can be exercised in the Simulator, where MetricKit never
    /// delivers anything. Debug builds only.
    ///
    /// The JSON follows the shape of MetricKit's `jsonRepresentation()` and is
    /// marked `"blauSample": true` so an exported sample can't be mistaken for
    /// real data.
    public enum DiagnosticsSamples {
        /// A day of metrics ending at `periodEnd`: three hangs, 312 MB peak
        /// memory, launch times and two of Blau's MetricKit signposts.
        public static func metricPayload(periodEnd: Date) -> CapturedPayload {
            let periodStart = periodEnd.addingTimeInterval(-24 * 60 * 60)
            let environment = PayloadEnvironment(
                appVersion: "0.1.0", appBuild: "1", osVersion: "iPhone OS 26.1 (23B85)", deviceType: "iPhone17,1",
                platformArchitecture: "arm64e", isTestFlightApp: true, isLowPowerModeEnabled: false)
            let summary = MetricPayloadSummary(
                periodStart: periodStart,
                periodEnd: periodEnd,
                environment: environment,
                latestAppVersion: "0.1.0",
                peakMemoryBytes: 312_000_000,
                averageSuspendedMemoryBytes: 48_000_000,
                cumulativeCPUSeconds: 1_840,
                cumulativeLogicalWriteBytes: 96_000_000,
                hangTime: DurationHistogram(buckets: [
                    .init(start: 0.25, end: 0.5, count: 2),
                    .init(start: 0.5, end: 1, count: 1),
                ]),
                timeToFirstDraw: DurationHistogram(buckets: [
                    .init(start: 0.3, end: 0.4, count: 5),
                    .init(start: 0.4, end: 0.5, count: 2),
                ]),
                resumeTime: DurationHistogram(buckets: [.init(start: 0.05, end: 0.1, count: 9)]),
                foregroundExits: AppExitCounts(normal: 4, memoryResourceLimit: 1),
                backgroundExits: AppExitCounts(normal: 6, memoryPressure: 2),
                signposts: [
                    SignpostMetricSummary(
                        category: "realtime", name: "realtime.firstAudio", totalCount: 40,
                        duration: DurationHistogram(buckets: [
                            .init(start: 0.4, end: 0.6, count: 25),
                            .init(start: 0.6, end: 1, count: 15),
                        ]),
                        cumulativeCPUSeconds: 3.2, averageMemoryBytes: 280_000_000),
                    SignpostMetricSummary(
                        category: "asr", name: "asr.eou", totalCount: 42,
                        duration: DurationHistogram(buckets: [.init(start: 0.1, end: 0.2, count: 42)])),
                ]
            )
            let json: [String: Any] = [
                "blauSample": true,
                "appVersion": "0.1.0",
                "timeStampBegin": timestamp(periodStart),
                "timeStampEnd": timestamp(periodEnd),
                "metaData": metaData,
                "memoryMetrics": [
                    "peakMemoryUsage": "312,000 kB",
                    "averageSuspendedMemory": [
                        "averageValue": "48,000 kB", "standardDeviation": 0, "sampleCount": 12,
                    ],
                ],
                "applicationResponsivenessMetrics": [
                    "histogrammedAppHangTime": histogram([("250 ms", "500 ms", 2), ("500 ms", "1,000 ms", 1)])
                ],
                "applicationLaunchMetrics": [
                    "histogrammedTimeToFirstDrawKey": histogram([("300 ms", "400 ms", 5), ("400 ms", "500 ms", 2)]),
                    "histogrammedResumeTime": histogram([("50 ms", "100 ms", 9)]),
                ],
                "signpostMetrics": [
                    [
                        "signpostCategory": "realtime", "signpostName": "realtime.firstAudio",
                        "totalSignpostCount": 40,
                        "signpostIntervalData": [
                            "histogrammedSignpostDurations": histogram([
                                ("400 ms", "600 ms", 25), ("600 ms", "1,000 ms", 15),
                            ])
                        ],
                    ]
                ],
            ]
            return CapturedPayload(json: encode(json), summary: .metrics(summary))
        }

        /// A diagnostic payload ending at `periodEnd`: a 2.5 s hang and a
        /// `SIGSEGV` crash.
        public static func diagnosticPayload(periodEnd: Date) -> CapturedPayload {
            let periodStart = periodEnd.addingTimeInterval(-60 * 60)
            let environment = PayloadEnvironment(
                appVersion: "0.1.0", appBuild: "1", osVersion: "iPhone OS 26.1 (23B85)", deviceType: "iPhone17,1",
                platformArchitecture: "arm64e", isTestFlightApp: true, isLowPowerModeEnabled: false)
            let summary = DiagnosticPayloadSummary(
                periodStart: periodStart,
                periodEnd: periodEnd,
                environment: environment,
                hangs: [HangEvent(durationSeconds: 2.5, appVersion: "0.1.0")],
                crashes: [CrashEvent(exceptionType: 1, exceptionCode: 0, signal: 11, appVersion: "0.1.0")]
            )
            let callStackTree: [String: Any] = [
                "callStackPerThread": true,
                "callStacks": [["threadAttributed": true, "callStackRootFrames": [] as [Any]]],
            ]
            let json: [String: Any] = [
                "blauSample": true,
                "timeStampBegin": timestamp(periodStart),
                "timeStampEnd": timestamp(periodEnd),
                "hangDiagnostics": [
                    [
                        "version": "1.0.0", "callStackTree": callStackTree, "diagnosticMetaData": metaData,
                        "hangDuration": "2.5 sec",
                    ]
                ],
                "crashDiagnostics": [
                    [
                        "version": "1.0.0", "callStackTree": callStackTree,
                        "diagnosticMetaData": metaData.merging(
                            ["exceptionType": 1, "exceptionCode": 0, "signal": 11]) { _, new in new },
                    ]
                ],
            ]
            return CapturedPayload(json: encode(json), summary: .diagnostics(summary))
        }

        private static var metaData: [String: Any] {
            [
                "appBuildVersion": "1",
                "appVersion": "0.1.0",
                "bundleIdentifier": "com.joeblau.blau",
                "deviceType": "iPhone17,1",
                "isTestFlightApp": true,
                "lowPowerModeEnabled": false,
                "osVersion": "iPhone OS 26.1 (23B85)",
                "platformArchitecture": "arm64e",
                "regionFormat": "US",
            ]
        }

        private static func histogram(_ buckets: [(String, String, Int)]) -> [String: Any] {
            var values: [String: Any] = [:]
            for (index, bucket) in buckets.enumerated() {
                values["\(index)"] = ["bucketStart": bucket.0, "bucketEnd": bucket.1, "bucketCount": bucket.2]
            }
            return ["histogramNumBuckets": buckets.count, "histogramValue": values]
        }

        private static func timestamp(_ date: Date) -> String {
            date.formatted(.iso8601)
        }

        private static func encode(_ json: [String: Any]) -> Data {
            // Only literal dictionaries of strings and numbers: this can't fail.
            (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        }
    }
#endif
