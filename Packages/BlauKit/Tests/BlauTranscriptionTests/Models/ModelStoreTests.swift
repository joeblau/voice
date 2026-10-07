import Foundation
import Testing

@testable import BlauTranscription

/// Writes `descriptor`'s fixture files into staging and installs them.
@discardableResult
func installFixture(_ descriptor: ModelDescriptor, in store: ModelStore) throws -> ModelInstallation {
    let staging = store.stagingDirectory(for: descriptor)
    for file in descriptor.files {
        let url = staging.appending(path: file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ModelFixtures.contents(of: file, in: descriptor).write(to: url)
    }
    return try store.install(descriptor, installedAt: Date(timeIntervalSinceReferenceDate: 0))
}

@Suite("Model store")
struct ModelStoreTests {
    let manifest = ModelFixtures.manifest(bytesPerFile: 4096)

    /// Acceptance criterion: models are excluded from backup.
    @Test func prepareExcludesTheStoreFromBackup() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url.appending(path: "Models"))
        #expect(try store.prepare())
        #expect(ModelStore.isExcludedFromBackup(store.root))

        // Installed models sit under the excluded root and are excluded too.
        let descriptor = try #require(manifest[.sileroVAD])
        let installation = try installFixture(descriptor, in: store)
        #expect(ModelStore.isExcludedFromBackup(installation.directory))
    }

    @Test func aNewDirectoryIsNotExcludedUntilPrepared() throws {
        let temp = try TemporaryDirectory()
        #expect(!ModelStore.isExcludedFromBackup(temp.url))
    }

    @Test func applicationSupportStoreLivesInApplicationSupport() throws {
        let store = try ModelStore.applicationSupport()
        #expect(store.root.path(percentEncoded: false).contains("Application Support/Blau/Models"))
    }

    @Test func installMovesStagingIntoPlaceWithAReceipt() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        try store.prepare()
        let descriptor = try #require(manifest[.parakeetRealtimeEOU])
        #expect(store.installation(of: descriptor) == nil)

        let installation = try installFixture(descriptor, in: store)
        #expect(installation.directory == store.directory(for: descriptor))
        #expect(
            installation.directory.path(percentEncoded: false).hasSuffix("parakeetRealtimeEOU/\(descriptor.revision)/"))
        #expect(store.installation(of: descriptor) == installation)
        #expect(
            !FileManager.default.fileExists(atPath: store.stagingDirectory(for: descriptor).path(percentEncoded: false))
        )
        #expect(store.corruptFiles(in: descriptor).isEmpty)
    }

    @Test func aMissingOrTruncatedFileMeansNotInstalled() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        let installation = try installFixture(descriptor, in: store)
        let file = try #require(descriptor.files.last)

        try Data([1, 2, 3]).write(to: installation.directory.appending(path: file.path))
        #expect(store.installation(of: descriptor) == nil)

        try FileManager.default.removeItem(at: installation.directory.appending(path: file.path))
        #expect(store.installation(of: descriptor) == nil)
    }

    @Test func aDifferentRevisionOrFileSetIsNotInstalled() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        try installFixture(descriptor, in: store)

        // Same directory name, different checksums: the receipt doesn't match.
        let changed = ModelDescriptor(
            id: descriptor.id, repository: descriptor.repository, revision: descriptor.revision,
            remoteDirectory: "",
            files: descriptor.files.map {
                ModelFile(path: $0.path, size: $0.size, sha256: String($0.sha256.reversed()))
            })
        #expect(store.installation(of: changed) == nil)

        let bumped = ModelDescriptor(
            id: descriptor.id, repository: descriptor.repository, revision: String(repeating: "b", count: 40),
            remoteDirectory: "", files: descriptor.files)
        #expect(store.installation(of: bumped) == nil)
    }

    @Test func corruptFilesFindsChangedBytes() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.speakerEmbedding])
        let installation = try installFixture(descriptor, in: store)
        let file = try #require(descriptor.files.first)
        let url = installation.directory.appending(path: file.path)
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xFF
        try bytes.write(to: url)

        // Same size, so the cheap check passes; the hash doesn't.
        #expect(store.installation(of: descriptor) != nil)
        #expect(store.corruptFiles(in: descriptor) == [file.path])
    }

    @Test func markWarmedUpIsRecorded() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        try installFixture(descriptor, in: store)
        #expect(store.installation(of: descriptor)?.warmedUpOn == nil)
        try store.markWarmedUp(descriptor, systemVersion: "iOS 26.1")
        #expect(store.installation(of: descriptor)?.warmedUpOn == "iOS 26.1")
    }

    @Test func removeDeletesInstalledAndPartialFiles() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.parakeetTDTv3])
        try installFixture(descriptor, in: store)
        let partial = store.stagingDirectory(for: descriptor).appending(path: "x.partial")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10_000).write(to: partial)
        #expect(store.diskUsage(of: .parakeetTDTv3) >= descriptor.totalBytes + 10_000)

        try store.remove(.parakeetTDTv3)
        #expect(store.installation(of: descriptor) == nil)
        #expect(store.diskUsage(of: .parakeetTDTv3) == 0)
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
    }

    @Test func diskUsageCountsOnlyThatModel() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let descriptor = try #require(manifest[.sileroVAD])
        try installFixture(descriptor, in: store)
        #expect(store.diskUsage(of: .sileroVAD) >= descriptor.totalBytes)
        #expect(store.diskUsage(of: .speakerEmbedding) == 0)
    }

    @Test func removeStaleContentKeepsOnlyCurrentRevisions() throws {
        let temp = try TemporaryDirectory()
        let store = ModelStore(root: temp.url)
        let current = try #require(manifest[.sileroVAD])
        let old = ModelDescriptor(
            id: .sileroVAD, repository: current.repository, revision: String(repeating: "0", count: 40),
            remoteDirectory: "", files: current.files)
        try installFixture(old, in: store)
        try installFixture(current, in: store)
        let retired = temp.url.appending(path: "someRetiredModel/abc")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let oldStaging = store.stagingDirectory(for: old)
        try FileManager.default.createDirectory(at: oldStaging, withIntermediateDirectories: true)

        let removed = store.removeStaleContent(keeping: manifest)

        #expect(removed == ["sileroVAD", "someRetiredModel"])
        #expect(store.installation(of: current) != nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: old).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: oldStaging.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: retired.path(percentEncoded: false)))
    }

    @Test func sha256MatchesCryptoKit() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "f")
        try Data("abc".utf8).write(to: url)
        #expect(try ModelStore.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data().write(to: url)
        #expect(try ModelStore.sha256(of: url) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
