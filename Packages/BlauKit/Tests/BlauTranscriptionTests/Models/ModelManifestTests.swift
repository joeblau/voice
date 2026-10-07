import Foundation
import Testing

@testable import BlauTranscription

@Suite("Pinned model manifest")
struct ModelManifestTests {
    let manifest = ModelManifest.pinned

    @Test func coversEveryModelOnce() {
        #expect(manifest.models.map(\.id) == [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3])
        #expect(manifest.required.map(\.id) == [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU])
        #expect(manifest.optional.map(\.id) == [.parakeetTDTv3])
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
    @Test(arguments: ModelID.allCases)
    func providesWhatFluidAudioLoads(id: ModelID) throws {
        let descriptor = try #require(manifest[id])
        let topLevel = Set(descriptor.files.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        let missing = FluidAudioModels.requiredEntries(for: id).subtracting(topLevel)
        #expect(missing.isEmpty, "\(id) is missing \(missing.sorted())")
    }

    @Test(arguments: ModelID.allCases)
    func comesFromTheRepositoryFluidAudioUses(id: ModelID) throws {
        let descriptor = try #require(manifest[id])
        let upstream = FluidAudioModels.upstream(for: id)
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
        #expect(try (430...530).contains(megabytes(.parakeetTDTv3)))
        #expect(try (1...10).contains(megabytes(.sileroVAD)))
        #expect(try (1...40).contains(megabytes(.speakerEmbedding)))
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
        #expect(shuffled.models.map(\.id) == [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3])
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
        for id in ModelID.allCases {
            #expect(!id.displayName.isEmpty)
            #expect(!id.summary.isEmpty)
        }
    }

    @Test func warmUpUsesFluidAudiosComputeUnits() {
        #expect(CoreMLModelWarmer.computeUnits(for: .parakeetTDTv3, bundle: "Preprocessor.mlmodelc") == .cpuOnly)
        #expect(CoreMLModelWarmer.computeUnits(for: .parakeetTDTv3, bundle: "Encoder.mlmodelc") == .cpuAndNeuralEngine)
        #expect(
            CoreMLModelWarmer.computeUnits(for: .parakeetRealtimeEOU, bundle: "streaming_encoder.mlmodelc")
                == .cpuAndNeuralEngine)
    }
}
