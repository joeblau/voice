@preconcurrency import AVFAudio
import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Voice ID evaluation dataset")
struct EvaluationDatasetTests {
    func recording(
        _ id: String, _ speaker: String, _ role: VoiceIDRecordingRole
    ) -> VoiceIDEvaluationRecording {
        VoiceIDEvaluationRecording(
            id: id, speaker: speaker, role: role, audio: AudioFrame(samples: [0.1, 0.2], sampleOffset: 0))
    }

    @Test func validatesTheSet() throws {
        let valid = [recording("o/e", "owner", .enrollment), recording("o/p", "owner", .probe)]
        let dataset = try VoiceIDEvaluationDataset(name: "n", consent: "Owner, 2026-10-07", recordings: valid)
        #expect(dataset.targetSpeakers == ["owner"])
        #expect(dataset.recordings(.probe).count == 1)

        #expect(throws: VoiceIDDatasetError.missingConsent) {
            try VoiceIDEvaluationDataset(name: "n", consent: "  \n", recordings: valid)
        }
        #expect(throws: VoiceIDDatasetError.noTargets) {
            try VoiceIDEvaluationDataset(name: "n", consent: "c", recordings: [recording("p", "x", .probe)])
        }
        #expect(throws: VoiceIDDatasetError.noProbes) {
            try VoiceIDEvaluationDataset(name: "n", consent: "c", recordings: [recording("e", "x", .enrollment)])
        }
        #expect(throws: VoiceIDDatasetError.duplicateRecording("o/p")) {
            try VoiceIDEvaluationDataset(name: "n", consent: "c", recordings: valid + [recording("o/p", "tv", .probe)])
        }
        #expect(throws: VoiceIDDatasetError.cohortOverlapsEvaluation(["owner"])) {
            try VoiceIDEvaluationDataset(
                name: "n", consent: "c", recordings: valid + [recording("c", "owner", .cohort)])
        }
    }

    @Test func decodesManifestsWithOpenSourceKinds() throws {
        let json = """
            {
              "name": "Owner set",
              "consent": "Recorded by the owner for Blau, 2026-10-07",
              "recordings": [
                {"path": "owner/kitchen-1.m4a", "speaker": "owner", "role": "enrollment"},
                {"path": "tv/news.wav", "speaker": "tv-news-1", "role": "probe", "source": "tv",
                 "tags": {"room": "living room", "distance": "3m"}},
                {"path": "radio.wav", "speaker": "radio-1", "role": "probe", "source": "radio"}
              ]
            }
            """
        let manifest = try JSONDecoder().decode(VoiceIDDatasetManifest.self, from: Data(json.utf8))
        #expect(manifest.recordings.count == 3)
        #expect(manifest.recordings[0].source == nil)
        #expect(manifest.recordings[1].source == .tv)
        #expect(manifest.recordings[1].tags?["distance"] == "3m")
        #expect(manifest.recordings[2].source?.rawValue == "radio")
        let encoded = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(VoiceIDDatasetManifest.self, from: encoded) == manifest)
    }

    /// Datasets/voice-id/manifest.example.json is what the owner copies;
    /// keep it valid.
    @Test func exampleManifestIsValid() throws {
        let data = try Data(contentsOf: RepoFiles.url("Datasets/voice-id/manifest.example.json"))
        let manifest = try JSONDecoder().decode(VoiceIDDatasetManifest.self, from: data)
        #expect(!manifest.consent.isEmpty)
        #expect(manifest.recordings.contains { $0.role == .enrollment && $0.speaker == "owner" })
        let sources = Set(manifest.recordings.compactMap(\.source))
        #expect(sources.isSuperset(of: [.person, .tv, .podcast, .music, .otherLanguage, .overlap]))
        let root = URL(filePath: "/dataset", directoryHint: .isDirectory)
        for entry in manifest.recordings {
            _ = try VoiceIDEvaluationDataset.resolve(entry.path, in: root)
        }
    }

    @Test func pathsStayInsideTheDataset() throws {
        let root = URL(filePath: "/data/set", directoryHint: .isDirectory)
        #expect(try VoiceIDEvaluationDataset.resolve("a/b.wav", in: root).path() == "/data/set/a/b.wav")
        for path in ["/etc/passwd", "../other/x.wav", "a/../../x.wav", ""] {
            #expect(throws: VoiceIDDatasetError.pathOutsideDataset(path)) {
                try VoiceIDEvaluationDataset.resolve(path, in: root)
            }
        }
    }

    @Test func loadsAndConvertsRecordings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "blau-voiceid-dataset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "owner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 48 kHz stereo with half a second of silence either side of 1 s of
        // tone, as a phone recording might be.
        try writeWAV(
            directory.appending(path: "owner/enroll.wav"), sampleRate: 48_000, channels: 2,
            seconds: 2, toneFrom: 0.5, toneTo: 1.5)
        try writeWAV(
            directory.appending(path: "probe.wav"), sampleRate: 16_000, channels: 1, seconds: 1, toneFrom: 0,
            toneTo: 1)
        let manifest = VoiceIDDatasetManifest(
            name: "files", consent: "test",
            recordings: [
                .init(path: "owner/enroll.wav", speaker: "owner", role: .enrollment),
                .init(path: "probe.wav", speaker: "other", role: .probe, source: .podcast, tags: ["room": "desk"]),
            ])
        let manifestURL = directory.appending(path: "manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let dataset = try VoiceIDEvaluationDataset.load(manifest: manifestURL)
        #expect(dataset.name == "files")
        let enrollment = try #require(dataset.recordings(.enrollment).first)
        #expect(enrollment.audio.sampleRate == 16_000)
        // Trimmed to the 1 s tone plus 50 ms either side.
        #expect(abs(enrollment.audio.duration.timeInterval - 1.1) < 0.03)
        #expect(enrollment.audio.peak > 0.3)
        let probe = try #require(dataset.recordings(.probe).first)
        #expect(probe.source == .podcast)
        #expect(probe.tags == ["room": "desk"])
        #expect(probe.audio.sampleCount == 16_000)

        let untrimmed = try VoiceIDEvaluationDataset.load(manifest: manifestURL, trimSilence: false)
        let raw = try #require(untrimmed.recordings(.enrollment).first)
        #expect(abs(raw.audio.duration.timeInterval - 2) < 0.01)
    }

    @Test func refusesManifestsWithoutConsentOrWithMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "blau-voiceid-dataset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "manifest.json")

        let noConsent = VoiceIDDatasetManifest(
            name: "n", consent: "",
            recordings: [.init(path: "missing.wav", speaker: "owner", role: .enrollment)])
        try JSONEncoder().encode(noConsent).write(to: url)
        #expect(throws: VoiceIDDatasetError.missingConsent) { try VoiceIDEvaluationDataset.load(manifest: url) }

        let missing = VoiceIDDatasetManifest(
            name: "n", consent: "c", recordings: [.init(path: "missing.wav", speaker: "owner", role: .enrollment)])
        try JSONEncoder().encode(missing).write(to: url)
        #expect(throws: VoiceIDDatasetError.self) { try VoiceIDEvaluationDataset.load(manifest: url) }
    }

    private func writeWAV(
        _ url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, toneFrom: Double,
        toneTo: Double
    ) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            for index in 0..<Int(frames) {
                let time = Double(index) / sampleRate
                data[index] = (toneFrom..<toneTo).contains(time) ? Float(0.5 * sin(2 * .pi * 440 * time)) : 0
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
