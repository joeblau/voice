import BlauPersistence
import BlauTopics
import Foundation
import SwiftUI

/// The accessibility identifiers of the topic edit controls.
enum TopicEditAccessibility {
    static let rename = "blau.topic.rename"
    static let merge = "blau.topic.mergeWithPrevious"
    static let split = "blau.topic.splitHere"
    static let titleField = "blau.topic.titleField"
}

/// The user's edits to topics (#54): rename, merge with the previous topic
/// and split at a line, applied through `AppEnvironment.topicLifecycle`, with
/// the rename prompt and the failure message they need.
///
/// One editor serves a whole screen (the timeline's bullets, its topic
/// details and their transcript rows), so the prompt and the alert are
/// presented once, by `topicEditorAlerts(_:)`, however many places can
/// start an edit. A renamed title is final and syncs to the user's other
/// devices.
@MainActor
@Observable
final class TopicEditor {
    /// A rename in progress: the topic and the title being typed.
    struct Rename: Equatable {
        let topicID: UUID
        var draft: String
    }

    /// The rename prompt's state, while it is up.
    var rename: Rename?
    /// The topics the user renamed here, so VoiceOver isn't told the title
    /// they just typed (`TopicAnnouncer`, #81).
    private(set) var renamedTopicIDs: Set<UUID> = []
    /// What went wrong, while the alert is up.
    struct Failure: Equatable {
        var title: String
        var message: String
    }

    /// Why the last action failed, while the alert is up.
    var failure: Failure?

    /// Shows the rename prompt, prefilled with `title`.
    func beginRename(_ topicID: UUID, title: String) {
        rename = Rename(topicID: topicID, draft: title)
    }

    /// Applies the rename prompt's title.
    func commitRename(using lifecycle: TopicLifecycle) {
        guard let rename else { return }
        self.rename = nil
        let title = rename.draft
        renamedTopicIDs.insert(rename.topicID)
        perform(using: lifecycle) { try await $0.rename(rename.topicID, to: title) }
    }

    func mergeWithPrevious(_ topicID: UUID, using lifecycle: TopicLifecycle) {
        perform(using: lifecycle) { _ = try await $0.mergeWithPrevious(topicID) }
    }

    /// Starts a new topic at `utteranceID`.
    func split(_ topicID: UUID, atUtterance utteranceID: UUID, using lifecycle: TopicLifecycle) {
        perform(using: lifecycle) { _ = try await $0.split(topicID, atUtterance: utteranceID) }
    }

    /// Shows the failure alert.
    func report(_ title: String, _ message: String) {
        failure = Failure(title: title, message: message)
    }

    private func perform(
        using lifecycle: TopicLifecycle, _ edit: @escaping @Sendable (TopicLifecycle) async throws -> Void
    ) {
        Task {
            do {
                try await edit(lifecycle)
            } catch {
                failure = Failure(title: "Couldn't Edit the Topic", message: TopicEditFailure.message(for: error))
            }
        }
    }
}

extension View {
    /// The context menu for a topic in the topics debug screen (#54): Rename
    /// and Merge with Previous, applied through
    /// `AppEnvironment.topicLifecycle`.
    ///
    /// - Parameters:
    ///   - topicID: The topic.
    ///   - title: Its current title, prefilled in the rename field.
    ///   - canMerge: `false` for a conversation's first topic.
    func topicEditMenu(topicID: UUID, title: String, canMerge: Bool) -> some View {
        modifier(TopicEditMenu(topicID: topicID, title: title, canMerge: canMerge))
    }

    /// "Split Here" for an utterance in a topic's transcript (#54): a new
    /// topic starts at this utterance.
    ///
    /// - Parameter isEnabled: `false` for the topic's first utterance.
    func splitTopicMenu(topicID: UUID, utteranceID: UUID, isEnabled: Bool) -> some View {
        modifier(SplitTopicMenu(topicID: topicID, utteranceID: utteranceID, isEnabled: isEnabled))
    }

    /// Presents `editor`'s rename prompt and failure alert.
    func topicEditorAlerts(_ editor: TopicEditor) -> some View {
        modifier(TopicEditorAlerts(editor: editor))
    }
}

/// Rename… and Merge with Previous, for a context menu or a `Menu`.
struct TopicEditMenuItems: View {
    let topicID: UUID
    let title: String
    let canMerge: Bool
    let editor: TopicEditor

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button("Rename…", systemImage: "pencil") {
            editor.beginRename(topicID, title: title)
        }
        .accessibilityIdentifier(TopicEditAccessibility.rename)
        Button("Merge with Previous", systemImage: "arrow.merge") {
            editor.mergeWithPrevious(topicID, using: environment.topicLifecycle)
        }
        .disabled(!canMerge)
        .accessibilityIdentifier(TopicEditAccessibility.merge)
    }
}

private struct TopicEditMenu: ViewModifier {
    let topicID: UUID
    let title: String
    let canMerge: Bool

    @State private var editor = TopicEditor()

    func body(content: Content) -> some View {
        content
            .contextMenu {
                TopicEditMenuItems(topicID: topicID, title: title, canMerge: canMerge, editor: editor)
            }
            .topicEditorAlerts(editor)
    }
}

private struct SplitTopicMenu: ViewModifier {
    let topicID: UUID
    let utteranceID: UUID
    let isEnabled: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var editor = TopicEditor()

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Split Here", systemImage: "scissors") {
                    editor.split(topicID, atUtterance: utteranceID, using: environment.topicLifecycle)
                }
                .disabled(!isEnabled)
                .accessibilityIdentifier(TopicEditAccessibility.split)
            }
            .topicEditorAlerts(editor)
    }
}

private struct TopicEditorAlerts: ViewModifier {
    @Bindable var editor: TopicEditor

    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Topic",
                isPresented: Binding(
                    get: { editor.rename != nil }, set: { if !$0 { editor.rename = nil } })
            ) {
                TextField(
                    "Title",
                    text: Binding(
                        get: { editor.rename?.draft ?? "" }, set: { editor.rename?.draft = $0 })
                )
                .accessibilityIdentifier(TopicEditAccessibility.titleField)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    editor.commitRename(using: environment.topicLifecycle)
                }
                .disabled((editor.rename?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(
                editor.failure?.title ?? "",
                isPresented: Binding(
                    get: { editor.failure != nil }, set: { if !$0 { editor.failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editor.failure?.message ?? "")
            }
    }
}

/// What to tell the user when an edit fails.
enum TopicEditFailure {
    static func message(for error: any Error) -> String {
        switch error {
        case ConversationStoreError.emptyTitle:
            "A topic needs a title."
        case ConversationStoreError.noPreviousTopic:
            "This is the conversation's first topic, so there's nothing to merge it into."
        case ConversationStoreError.topicNotFound:
            "This topic no longer exists."
        case TopicLifecycle.EditError.splitAtFirstUtterance:
            "A topic can't be split at its first line."
        default:
            "The topic couldn't be changed."
        }
    }
}
