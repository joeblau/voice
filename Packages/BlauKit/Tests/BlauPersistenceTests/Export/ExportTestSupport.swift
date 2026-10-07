import BlauCore
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauPersistence

/// `2026-10-08T21:03:00Z` (14:03 in Los Angeles, PDT).
let exportT0 = Date(timeIntervalSince1970: 1_791_493_380)

let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// `exportT0` plus `minutes` and `seconds`.
func exportTime(_ minutes: Double, _ seconds: Double = 0) -> Date {
    exportT0.addingTimeInterval(minutes * 60 + seconds)
}

/// An export folder in a temporary directory, removed with the value.
final class ExportFolder {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// The folder the exporter writes into (created by the exporter).
    var url: URL { directory.url.appending(path: "Documents", directoryHint: .isDirectory) }

    var destination: MarkdownExportDestination { .directory(url) }

    /// File names in the folder, sorted.
    func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    func contents(of name: String) throws -> String {
        try String(contentsOf: url.appending(path: name), encoding: .utf8)
    }

    func modificationDate(of name: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.appending(path: name).path(percentEncoded: false))[
            .modificationDate] as? Date
    }

    func write(_ text: String, to name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appending(path: name))
    }
}

/// Inserts a conversation with topics and utterances into `context` and
/// saves. Each topic is `(title, start minute, end minute)`; each utterance
/// `(topic index or nil, minute, role, text)`.
@discardableResult
func insertConversation(
    into context: ModelContext,
    id: UUID = UUID(),
    title: String? = nil,
    start: Double = 0,
    end: Double? = 60,
    topics: [(String, Double, Double?)] = [("Hiring Plan", 0, 60)],
    utterances: [(Int?, Double, UtteranceRole, String)] = [(0, 1, .user, "Hello there.")]
) throws -> Conversation {
    let conversation = Conversation(
        id: id, startedAt: exportTime(start), endedAt: end.map { exportTime($0) }, title: title)
    context.insert(conversation)
    let stored = topics.enumerated().map { index, topic in
        let model = Topic(
            conversation: conversation, startedAt: exportTime(topic.1), endedAt: topic.2.map { exportTime($0) },
            title: topic.0, titleIsProvisional: false, ordinal: index)
        context.insert(model)
        return model
    }
    for utterance in utterances {
        context.insert(
            StoredUtterance(
                conversation: conversation, topic: utterance.0.map { stored[$0] }, role: utterance.2,
                text: utterance.3, startedAt: exportTime(utterance.1), isFinal: true, source: .parakeet))
    }
    try context.save()
    return conversation
}

/// A file system that records every write and can be told to fail.
final class RecordingFileSystem: MarkdownExportFileSystem {
    private struct State {
        var writes: [String] = []
        var moves: [(String, String)] = []
        var removals: [String] = []
        var failingNames: Set<String> = []
        var failsListing = false
    }

    struct InjectedFailure: Error {}

    private let base = CoordinatedMarkdownFileSystem()
    private let state = Mutex(State())

    var writes: [String] { state.withLock { $0.writes } }
    var moves: [(String, String)] { state.withLock { $0.moves } }
    var removals: [String] { state.withLock { $0.removals } }

    /// Makes writes to files whose name contains `fragment` fail.
    func failWrites(containing fragment: String) {
        _ = state.withLock { $0.failingNames.insert(fragment) }
    }

    func failListing() {
        state.withLock { $0.failsListing = true }
    }

    func reset() {
        state.withLock { state in
            state.writes = []
            state.moves = []
            state.removals = []
        }
    }

    func prepareDirectory(_ directory: URL) throws {
        try base.prepareDirectory(directory)
    }

    func contentsOfDirectory(_ directory: URL) throws -> [URL] {
        if state.withLock({ $0.failsListing }) { throw InjectedFailure() }
        return try base.contentsOfDirectory(directory)
    }

    func read(_ url: URL) throws -> Data {
        try base.read(url)
    }

    func write(_ data: Data, to url: URL) throws {
        let name = url.lastPathComponent
        let fails = state.withLock { state in
            state.writes.append(name)
            return state.failingNames.contains { name.contains($0) }
        }
        if fails { throw InjectedFailure() }
        try base.write(data, to: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        state.withLock { $0.moves.append((source.lastPathComponent, destination.lastPathComponent)) }
        try base.move(source, to: destination)
    }

    func remove(_ url: URL) throws {
        state.withLock { $0.removals.append(url.lastPathComponent) }
        try base.remove(url)
    }
}
