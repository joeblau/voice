#if DEBUG
    import BlauAudio
    import BlauCore
    import BlauTelemetry
    import BlauTranscription
    import Foundation
    import Observation
    import os

    /// Drives a long-session soak run on a device (#26, docs/background.md):
    /// the live conversation audio (the `AudioSessionKeeper` the app uses),
    /// with the VAD running on the captured audio (Silero on Core ML when
    /// the model is installed) and registered with the background inference
    /// monitor. Lock the device and leave it; stop the run to get a
    /// `LongSessionReport`.
    ///
    /// Until streaming ASR (#29) and the turn orchestrator (#36) exist, the
    /// VAD is the Core ML stage that runs for the whole session, so it stands
    /// in for "transcribes" in the 30-minute acceptance test.
    @MainActor
    @Observable
    final class LongSessionSoak {
        private(set) var keeper: AudioSessionKeeper.Snapshot?
        private(set) var inference: BackgroundInferenceMonitor.Snapshot?
        private(set) var vad: VoiceActivityStatistics?
        private(set) var capture: CaptureStatistics?
        private(set) var vadModel = ""
        private(set) var isRunning = false
        private(set) var error: String?
        private(set) var report: LongSessionReport?
        /// Where the latest report was saved, for sharing.
        private(set) var reportURL: URL?

        @ObservationIgnored private var startedAt: Date?
        @ObservationIgnored private var segmenter: VoiceActivitySegmenter?
        @ObservationIgnored private var vadTask: Task<Void, Never>?
        @ObservationIgnored private var pollTask: Task<Void, Never>?
        @ObservationIgnored private var registeredStage: String?

        func start(_ environment: AppEnvironment) async {
            guard !isRunning else { return }
            guard let conversation = environment.conversationAudio else {
                error = "The soak test needs the live app (this environment runs on fakes)."
                return
            }
            error = nil
            report = nil
            reportURL = nil
            do {
                try await conversation.keeper.startCapture()
            } catch {
                self.error = "Couldn't start the microphone: \(error)"
                return
            }
            isRunning = true
            startedAt = Date()

            let model: any SpeechProbabilityModel
            if let directory = environment.speechModels.directory(for: .sileroVAD),
                let silero = try? await SileroSpeechProbabilityModel(modelDirectory: directory)
            {
                model = silero
                vadModel = "Silero VAD (Core ML)"
                await environment.backgroundInference.register(silero, budget: .milliseconds(256))
                registeredStage = silero.inferenceStage
            } else {
                model = EnergySpeechProbabilityModel()
                vadModel = "Energy (Silero isn't installed)"
            }
            let segmenter = VoiceActivitySegmenter(model: model, inferenceObserver: environment.backgroundInference)
            self.segmenter = segmenter
            let hub = conversation.capture.hub
            vadTask = Task { await segmenter.run(on: hub) }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(environment)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            Log.ui.notice("Long-session soak started (\(self.vadModel, privacy: .public))")
        }

        func stop(_ environment: AppEnvironment) async {
            guard isRunning, let conversation = environment.conversationAudio else { return }
            pollTask?.cancel()
            vadTask?.cancel()
            await vadTask?.value
            if let registeredStage {
                await environment.backgroundInference.unregister(stage: registeredStage)
            }
            await refresh(environment)
            await conversation.keeper.stopCapture()
            isRunning = false

            let keeperStatistics = keeper?.statistics ?? AudioSessionKeeper.Statistics()
            let report = LongSessionReport(
                device: .current,
                startedAt: startedAt ?? Date(),
                endedAt: Date(),
                finalStatus: keeper.map { "\($0.status)" } ?? "unknown",
                keeper: keeperStatistics,
                capture: LongSessionReport.Capture(capture ?? CaptureStatistics()),
                vad: vad.map { LongSessionReport.VAD(model: vadModel, statistics: $0) },
                inference: await environment.backgroundInference.snapshot
            )
            self.report = report
            reportURL = save(report)
            segmenter = nil
            registeredStage = nil
            Log.ui.notice(
                "Long-session soak stopped: \(report.verdict.passed ? "passed" : "failed", privacy: .public)")
        }

        private func refresh(_ environment: AppEnvironment) async {
            guard let conversation = environment.conversationAudio else { return }
            keeper = await conversation.keeper.snapshot
            inference = await environment.backgroundInference.snapshot
            capture = conversation.capture.hub.statistics
            vad = segmenter?.statistics
        }

        private func save(_ report: LongSessionReport) -> URL? {
            do {
                let directory = URL.documentsDirectory.appending(path: "LongSession", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = report.startedAt.formatted(
                    .iso8601.year().month().day().time(includingFractionalSeconds: false)
                )
                .replacingOccurrences(of: ":", with: "-")
                let url = directory.appending(path: "\(name).json")
                try report.jsonData().write(to: url)
                return url
            } catch {
                self.error = "Couldn't save the report: \(error)"
                return nil
            }
        }
    }
#endif
