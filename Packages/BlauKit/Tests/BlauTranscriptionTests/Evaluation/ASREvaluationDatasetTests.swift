import Foundation
import Testing

@testable import BlauTranscription

@Suite("ASR evaluation dataset")
struct ASREvaluationDatasetTests {
    // MARK: The bundled fixtures

    @Test func theBundledManifestCoversTheIssuesConditions() throws {
        let manifest = try ASREvaluationDataset.manifest(at: ASRFixtures.manifestURL())
        #expect(!manifest.consent.isEmpty)
        #expect(manifest.sampleRate == 16_000)
        #expect((20...30).contains(manifest.fixtures.count), "The issue asks for 20 to 30 fixtures")
        let categories = Set(manifest.fixtures.map(\.category))
        #expect(categories.isSuperset(of: ["clean", "cafe", "tv", "accented"]))
        #expect(Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count)
        for entry in manifest.fixtures {
            #expect(entry.path == "\(entry.id).wav")
            #expect(entry.id.hasPrefix(entry.category))
            #expect(!entry.utterances.isEmpty)
            var previousEnd: Int64 = 0
            for utterance in entry.utterances {
                #expect(utterance.start >= previousEnd && utterance.end > utterance.start, "\(entry.id)")
                #expect(utterance.end <= entry.sampleCount ?? .max, "\(entry.id)")
                // References are written as spoken: no digits or symbols for
                // the normalizer to reinterpret.
                #expect(utterance.text.allSatisfy { $0.isLetter || $0 == " " || $0 == "'" }, "\(entry.id)")
                previousEnd = utterance.end
            }
            // Room for the VAD fallback (0.9 s after VAD's end of speech)
            // before the file ends.
            let tail = (entry.sampleCount ?? 0) - (entry.utterances.last?.end ?? 0)
            #expect(tail >= 32_000, "\(entry.id) ends \(tail) samples after its speech")
        }
    }

    @Test(.enabled(if: ASRFixtures.audioIsAvailable, "The fixture audio is in Git LFS: run git lfs pull"))
    func theBundledAudioMatchesItsLabels() throws {
        let dataset = try ASREvaluationDataset.load(manifest: ASRFixtures.manifestURL())
        #expect(dataset.fixtures.count >= 20)
        #expect(dataset.categories == ["clean", "cafe", "tv", "accented"])
        for fixture in dataset.fixtures {
            // Speech is louder than what surrounds it.
            let first = try #require(fixture.utterances.first).range
            let lead = fixture.samples[0..<Int(first.lowerBound)]
            let speech = fixture.samples[Int(first.lowerBound)..<Int(first.upperBound)]
            #expect(rms(speech) > rms(lead) * 1.5, "\(fixture.id)")
        }
        #expect(dataset.audioSeconds > 120)
    }

    // MARK: Loading

    @Test func loadsAManifestAndConvertsPositionsFromItsSampleRate() throws {
        let directory = try ASRTemporaryDirectory()
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.05)) * 0.2 }
        try directory.write(wavData(samples, sampleRate: 48_000), to: "audio/one.wav")
        let manifest = ASREvaluationManifest(
            name: "test", consent: "synthetic", sampleRate: 48_000,
            fixtures: [
                .init(
                    id: "one", path: "audio/one.wav", category: "clean", sampleCount: 48_000,
                    utterances: [.init(start: 4_800, end: 24_000, text: "Hello there")], tags: ["voice": "x"])
            ])
        let dataset = try ASREvaluationDataset.load(manifest: directory.writeManifest(manifest))
        let fixture = try #require(dataset.fixtures.first)
        #expect(abs(fixture.samples.count - 16_000) <= 2)
        #expect(fixture.utterances == [ASRReferenceUtterance(range: 1_600..<8_000, text: "Hello there")])
        #expect(fixture.tags == ["voice": "x"])
        #expect(fixture.reference == "Hello there")
        #expect(dataset.utteranceCount == 1)
    }

    @Test func filtersByCategoryAndFixture() throws {
        let directory = try ASRTemporaryDirectory()
        try directory.write(wavData([Float](repeating: 0.1, count: 16_000)), to: "a.wav")
        try directory.write(wavData([Float](repeating: 0.1, count: 16_000)), to: "b.wav")
        let url = try directory.writeManifest(
            ASREvaluationManifest(
                name: "test", consent: "synthetic",
                fixtures: [
                    .init(
                        id: "a", path: "a.wav", category: "clean", utterances: [.init(start: 0, end: 8_000, text: "a")]),
                    .init(id: "b", path: "b.wav", category: "tv", utterances: [.init(start: 0, end: 8_000, text: "b")]),
                ]))
        #expect(try ASREvaluationDataset.load(manifest: url, categories: ["tv"]).fixtures.map(\.id) == ["b"])
        #expect(try ASREvaluationDataset.load(manifest: url, fixtureIDs: ["a"]).fixtures.map(\.id) == ["a"])
        #expect(throws: ASREvaluationDatasetError.noFixtures) {
            try ASREvaluationDataset.load(manifest: url, categories: ["cafe"])
        }
    }

    @Test func refusesLFSPointersWithInstructions() throws {
        let directory = try ASRTemporaryDirectory()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 123\n"
        try directory.write(Data(pointer.utf8), to: "a.wav")
        let url = try directory.writeManifest(
            ASREvaluationManifest(
                name: "test", consent: "synthetic",
                fixtures: [
                    .init(id: "a", path: "a.wav", category: "clean", utterances: [.init(start: 0, end: 1, text: "a")])
                ]
            ))
        #expect(ASREvaluationDataset.isLFSPointer(directory.url.appending(path: "a.wav")))
        #expect(!ASREvaluationDataset.audioIsAvailable(manifest: url))
        #expect(throws: ASREvaluationDatasetError.lfsPointer("a.wav")) {
            try ASREvaluationDataset.load(manifest: url)
        }
        #expect(ASREvaluationDatasetError.lfsPointer("a.wav").description.contains("git lfs pull"))
    }

    @Test func refusesBadManifests() throws {
        let directory = try ASRTemporaryDirectory()
        try directory.write(wavData([Float](repeating: 0.1, count: 16_000)), to: "a.wav")
        func load(_ fixtures: [ASREvaluationManifest.Entry], consent: String = "synthetic") throws {
            let url = try directory.writeManifest(
                ASREvaluationManifest(name: "test", consent: consent, fixtures: fixtures))
            _ = try ASREvaluationDataset.load(manifest: url)
        }
        let ok = ASREvaluationManifest.Utterance(start: 0, end: 8_000, text: "fine")

        #expect(throws: ASREvaluationDatasetError.missingConsent) {
            try load([.init(id: "a", path: "a.wav", category: "clean", utterances: [ok])], consent: " ")
        }
        #expect(throws: ASREvaluationDatasetError.pathOutsideDataset("../a.wav")) {
            try load([.init(id: "a", path: "../a.wav", category: "clean", utterances: [ok])])
        }
        #expect(throws: ASREvaluationDatasetError.pathOutsideDataset("/etc/a.wav")) {
            try load([.init(id: "a", path: "/etc/a.wav", category: "clean", utterances: [ok])])
        }
        #expect(throws: ASREvaluationDatasetError.duplicateFixture("a")) {
            try load([
                .init(id: "a", path: "a.wav", category: "clean", utterances: [ok]),
                .init(id: "a", path: "a.wav", category: "clean", utterances: [ok]),
            ])
        }
        #expect(throws: ASREvaluationDatasetError.lengthMismatch(path: "a.wav", expected: 20_000, actual: 16_000)) {
            try load([.init(id: "a", path: "a.wav", category: "clean", sampleCount: 20_000, utterances: [ok])])
        }
        #expect(throws: ASREvaluationDatasetError.self) {
            try load([
                .init(id: "a", path: "a.wav", category: "clean", utterances: [.init(start: 0, end: 20_000, text: "x")])
            ])
        }
        #expect(throws: ASREvaluationDatasetError.self) {
            try load([
                .init(
                    id: "a", path: "a.wav", category: "clean",
                    utterances: [.init(start: 0, end: 8_000, text: "x"), .init(start: 4_000, end: 9_000, text: "y")])
            ])
        }
        #expect(throws: ASREvaluationDatasetError.self) {
            try load([
                .init(id: "a", path: "a.wav", category: "clean", utterances: [.init(start: 0, end: 8_000, text: " ")])
            ])
        }
        #expect(throws: ASREvaluationDatasetError.self) {
            try load([.init(id: "a", path: "a.wav", category: "clean", utterances: [])])
        }
        #expect(throws: ASREvaluationDatasetError.self) {
            try load([.init(id: "a", path: "missing.wav", category: "clean", utterances: [ok])])
        }
    }

    func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }
}
