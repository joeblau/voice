import Foundation
import Testing

@testable import BlauTranscription

@Suite("Pinned model manifest")
struct ModelManifestTests {
    let manifest = ModelManifest.pinned

    @Test func coversEveryModelOnce() {
        #expect(
            manifest.models.map(\.id) == [
                .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3, .parakeetRealtimeEOU1280,
                .languageID,
            ])
        #expect(manifest.required.map(\.id) == [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU])
        #expect(manifest.optional.map(\.id) == [.parakeetTDTv3, .parakeetRealtimeEOU1280, .languageID])
    }

    @Test(arguments: ModelManifest.pinned.models)
    func pinsAnImmutableCommit(descriptor: ModelDescriptor) {
        #expect(descriptor.revision.count == 40, "\(descriptor.id) must pin a full commit SHA, not a branch")
        #expect(descriptor.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test(arguments: ModelManifest.pinned.models)
    func listsEveryFileWithSizeAndChecksum(descriptor: ModelDescriptor) {
        #expect(!descriptor.files.isEmpty)
        #expect(Set(descriptor.files.map(\.path)).count == descriptor.files.count)
        for file in descriptor.files {
            #expect(file.size > 0, "\(file.path)")
            #expect(
                file.sha256.count == 64 && file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(file.path)")
            #expect(!file.path.hasPrefix("/") && !file.path.contains(".."), "\(file.path)")
        }
    }

    /// Every compiled bundle needs the files Core ML reads.
    @Test(arguments: ModelManifest.pinned.models)
    func bundlesAreComplete(descriptor: ModelDescriptor) {
        #expect(!descriptor.bundles.isEmpty)
        let paths = Set(descriptor.files.map(\.path))
        for bundle in descriptor.bundles {
            for required in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                #expect(paths.contains("\(bundle)/\(required)"), "\(bundle) is missing \(required)")
            }
        }
    }

    /// FluidAudio's local loaders read fixed file names; the manifest must
    /// ship each one.
    @Test(arguments: FluidAudioModels.models)
    func providesWhatFluidAudioLoads(id: ModelID) throws {
        let descriptor = try #require(manifest[id])
        let topLevel = Set(descriptor.files.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        let missing = FluidAudioModels.requiredEntries(for: id).subtracting(topLevel)
        #expect(missing.isEmpty, "\(id) is missing \(missing.sorted())")
    }

    @Test(arguments: FluidAudioModels.models)
    func comesFromTheRepositoryFluidAudioUses(id: ModelID) throws {
        let descriptor = try #require(manifest[id])
        let upstream = try #require(FluidAudioModels.upstream(for: id))
        #expect(descriptor.repository == upstream.repository)
        #expect(descriptor.remoteDirectory == upstream.directory)
        if upstream.revision != "main" {
            // Where FluidAudio pins a commit itself, use the same one.
            #expect(descriptor.revision == upstream.revision)
        }
    }

    @Test func fluidAudioNamesAreTheOnesBlauExpects() {
        #expect(FluidAudioModels.vadModelBundle == "silero-vad-unified-256ms-v6.2.1.mlmodelc")
        #expect(FluidAudioModels.speakerEmbeddingBundle == "wespeaker_v2.mlmodelc")
        #expect(FluidAudioModels.requiredEntries(for: .parakeetRealtimeEOU).contains("vocab.json"))
    }

    /// Sizes from the issue: ~225 MB realtime EOU, ~480 MB TDT v3.
    @Test func sizesMatchTheExpectedModels() throws {
        let megabytes = { (id: ModelID) throws -> Int64 in try #require(manifest[id]).totalBytes / 1_000_000 }
        #expect(try (200...250).contains(megabytes(.parakeetRealtimeEOU)))
        #expect(try (200...250).contains(megabytes(.parakeetRealtimeEOU1280)))
        #expect(try (430...530).contains(megabytes(.parakeetTDTv3)))
        #expect(try (1...10).contains(megabytes(.sileroVAD)))
        #expect(try (1...40).contains(megabytes(.speakerEmbedding)))
        #expect(try (40...45).contains(megabytes(.languageID)))
    }

    @Test func buildsResolveURLsAtThePinnedRevision() throws {
        let descriptor = try #require(manifest[.parakeetRealtimeEOU])
        let file = try #require(descriptor.files.first { $0.path == "vocab.json" })
        #expect(
            descriptor.remoteURL(for: file).absoluteString
                == "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/\(descriptor.revision)/320ms/vocab.json"
        )
        let root = try #require(manifest[.sileroVAD])
        let weights = try #require(root.files.first { $0.path.hasSuffix("weights/weight.bin") })
        #expect(
            root.remoteURL(for: weights, host: URL(string: "https://mirror.example")!).absoluteString
                == "https://mirror.example/FluidInference/silero-vad-coreml/resolve/\(root.revision)/silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin"
        )
    }

    @Test func manifestOrdersRequiredModelsFirst() {
        let shuffled = ModelManifest(models: ModelFixtures.manifest().models.reversed())
        #expect(
            shuffled.models.map(\.id) == [
                .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3, .textEmbedding,
                .parakeetRealtimeEOU1280, .languageID,
            ])
    }

    @Test func descriptorsSortFilesAndFindBundles() {
        let descriptor = ModelDescriptor(
            id: .sileroVAD, repository: "o/r", revision: String(repeating: "a", count: 40), remoteDirectory: "",
            files: [
                ModelFile(path: "b.mlmodelc/model.mil", size: 1, sha256: ""),
                ModelFile(path: "vocab.json", size: 2, sha256: ""),
                ModelFile(path: "a.mlmodelc/coremldata.bin", size: 3, sha256: ""),
            ])
        #expect(descriptor.files.map(\.path) == ["a.mlmodelc/coremldata.bin", "b.mlmodelc/model.mil", "vocab.json"])
        #expect(descriptor.bundles == ["a.mlmodelc", "b.mlmodelc"])
        #expect(descriptor.totalBytes == 6)
    }

    @Test func requiredModelsAreTheOnesBlauCannotListenWithout() {
        #expect(ModelID.allCases.filter(\.isRequired) == [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU])
        #expect(
            ModelID.allCases.filter(\.followsOptionalModelsPreference) == [.parakeetTDTv3, .parakeetRealtimeEOU1280])
        for id in ModelID.allCases {
            #expect(!id.displayName.isEmpty)
            #expect(!id.summary.isEmpty)
            #expect(!id.deletionNote.isEmpty)
        }
    }

    /// Blau's own text embedding model (#60) is pinned here once the
    /// converted model is hosted; FluidAudio never loads it.
    @Test func theTextEmbeddingModelIsNotAFluidAudioModel() {
        #expect(!FluidAudioModels.models.contains(.textEmbedding))
        #expect(FluidAudioModels.upstream(for: .textEmbedding) == nil)
        #expect(FluidAudioModels.requiredEntries(for: .textEmbedding).isEmpty)
        #expect(Set(FluidAudioModels.models).isSubset(of: Set(manifest.models.map(\.id))))
    }

    /// The language filter's model (#50) is BlauVoiceID's own Core ML
    /// model: pinned here with the label list its loader checks, never
    /// loaded by FluidAudio, and optional (Blau listens without it).
    @Test func theLanguageIDModelIsPinnedWithItsLabels() throws {
        #expect(!FluidAudioModels.models.contains(.languageID))
        #expect(FluidAudioModels.upstream(for: .languageID) == nil)
        let descriptor = try #require(manifest[.languageID])
        #expect(descriptor.bundles == ["SpeechBrainECAPAVoxLingua107.mlmodelc"])
        #expect(descriptor.files.contains { $0.path == "labels.json" })
        #expect(!ModelID.languageID.isRequired)
        #expect(!ModelID.languageID.followsOptionalModelsPreference)
        // Warmed up for the CPU, where BlauVoiceID runs it.
        #expect(
            CoreMLModelWarmer.computeUnits(for: .languageID, bundle: "SpeechBrainECAPAVoxLingua107.mlmodelc")
                == .cpuOnly)
    }

    /// Each streaming chunk size Blau can switch to has its own export,
    /// from the matching directory of the same repository.
    @Test func chunkSizeExportsComeFromTheirOwnDirectories() throws {
        #expect(ASRChunkSize.ms320.modelID == .parakeetRealtimeEOU)
        #expect(ASRChunkSize.ms1280.modelID == .parakeetRealtimeEOU1280)
        #expect(ASRChunkSize.ms160.modelID == nil)
        let standard = try #require(manifest[.parakeetRealtimeEOU])
        let lowPower = try #require(manifest[.parakeetRealtimeEOU1280])
        #expect(lowPower.repository == standard.repository)
        #expect(lowPower.revision == standard.revision)
        #expect(standard.remoteDirectory == "320ms")
        #expect(lowPower.remoteDirectory == "1280ms")
        #expect(lowPower.bundles == standard.bundles)
        // Different exports: the encoder weights differ.
        let encoder = "streaming_encoder.mlmodelc/weights/weight.bin"
        #expect(
            lowPower.files.first { $0.path == encoder }?.sha256 != standard.files.first { $0.path == encoder }?.sha256)
        #expect(!ModelID.parakeetRealtimeEOU1280.isRequired)
    }

    @Test func warmUpUsesFluidAudiosComputeUnits() {
        #expect(CoreMLModelWarmer.computeUnits(for: .parakeetTDTv3, bundle: "Preprocessor.mlmodelc") == .cpuOnly)
        #expect(CoreMLModelWarmer.computeUnits(for: .parakeetTDTv3, bundle: "Encoder.mlmodelc") == .cpuAndNeuralEngine)
        #expect(
            CoreMLModelWarmer.computeUnits(for: .parakeetRealtimeEOU, bundle: "streaming_encoder.mlmodelc")
                == .cpuAndNeuralEngine)
    }
}
