import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import CoreTransferable
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Reads one topic's conversation out of the store for the topic detail's
/// actions (#58): "Share as Markdown" and "Continue This Topic".
///
/// Each read opens a fresh `ModelContext` off the main actor
/// (`SwiftDataConversationExportSource`, the Markdown export's reader), so a
/// long conversation never blocks a frame and nothing it reads is shared
/// with the views' context.
enum TopicSource {
    /// The conversation `topic` belongs to, as stored, or `nil` when it no
    /// longer exists.
    @concurrent
    static func conversation(of topic: TimelineTopic, in container: ModelContainer) async throws
        -> ConversationExportSnapshot?
    {
        try SwiftDataConversationExportSource(modelContainer: container).snapshot(of: topic.conversationID)
    }

    /// What Grok is told when the user continues `topic` (#58): its title,
    /// summary and lines as stored. `nil` when the topic is gone or empty.
    static func continuedTopic(_ topic: TimelineTopic, in container: ModelContainer) async throws
        -> RealtimeContinuedTopic?
    {
        guard let conversation = try await conversation(of: topic, in: container) else { return nil }
        return RealtimeContinuedTopic(topicID: topic.id, of: conversation)
    }
}

/// A topic shared as a Markdown file (#58), rendered only when the share
/// sheet asks for it: tapping Share costs nothing until the user picks a
/// destination.
///
/// The file has the same format as the conversation export (#78,
/// `TopicMarkdownRenderer`). Destinations that take text rather than files
/// (Messages, Notes) get the same Markdown as plain text.
struct TopicMarkdownDocument: Transferable {
    let topic: TimelineTopic
    let container: ModelContainer

    /// Markdown (`net.daringfireball.markdown`). iOS 27 names it
    /// `UTType.markdown`; iOS 26 knows the identifier from the system's
    /// declarations, and plain UTF-8 text stands in should it not.
    static let markdownType: UTType = {
        if #available(iOS 27, *) {
            return .markdown
        }
        return UTType("net.daringfireball.markdown") ?? .utf8PlainText
    }()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: markdownType) { document in
            SentTransferredFile(try await document.writeFile())
        }
        DataRepresentation(exportedContentType: .utf8PlainText) { document in
            Data(try await document.render().text.utf8)
        }
    }

    /// The rendered document and its file name.
    func render() async throws -> (text: String, fileName: String) {
        guard let conversation = try await TopicSource.conversation(of: topic, in: container) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let renderer = TopicMarkdownRenderer(timeZone: .current)
        return (
            renderer.render(topicID: topic.id, of: conversation), renderer.fileName(topicID: topic.id, of: conversation)
        )
    }

    /// Writes the document to a folder of its own in the temporary
    /// directory (the share sheet copies it), named after the topic.
    @concurrent
    func writeFile() async throws -> URL {
        let (text, fileName) = try await render()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Shared Topics", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url, options: .atomic)
        Log.ui.notice("Shared a topic as Markdown (\(text.utf8.count, privacy: .public) bytes)")
        return url
    }
}

/// "Continue This Topic" (#58): starts a conversation that picks up a topic,
/// or hands the topic to the running one. `MainScreenScaffold` provides it,
/// since the record button's model lives there.
struct TopicContinuationAction {
    let perform: @MainActor (TimelineTopic) async -> Void

    @MainActor
    func callAsFunction(_ topic: TimelineTopic) async {
        await perform(topic)
    }
}

extension EnvironmentValues {
    /// Continues a topic; `nil` where no conversation can be started (the
    /// action isn't offered then).
    @Entry var continueTopic: TopicContinuationAction?
}
