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

extension View {
    /// The context menu for a topic in the timeline (#54): Rename and Merge
    /// with Previous, applied through `AppEnvironment.topicLifecycle`. A
    /// renamed title is final and syncs to the user's other devices.
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
}

private struct TopicEditMenu: ViewModifier {
    let topicID: UUID
    let title: String
    let canMerge: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var isRenaming = false
    @State private var draft = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename…", systemImage: "pencil") {
                    draft = title
                    isRenaming = true
                }
                .accessibilityIdentifier(TopicEditAccessibility.rename)
                Button("Merge with Previous", systemImage: "arrow.merge") {
                    perform { try await $0.mergeWithPrevious(topicID) }
                }
                .disabled(!canMerge)
                .accessibilityIdentifier(TopicEditAccessibility.merge)
            }
            .alert("Rename Topic", isPresented: $isRenaming) {
                TextField("Title", text: $draft)
                    .accessibilityIdentifier(TopicEditAccessibility.titleField)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let title = draft
                    perform { try await $0.rename(topicID, to: title) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .topicEditFailureAlert($failure)
    }

    private func perform(_ edit: @escaping @Sendable (TopicLifecycle) async throws -> Void) {
        let lifecycle = environment.topicLifecycle
        Task {
            do {
                try await edit(lifecycle)
            } catch {
                failure = TopicEditFailure.message(for: error)
            }
        }
    }
}

private struct SplitTopicMenu: ViewModifier {
    let topicID: UUID
    let utteranceID: UUID
    let isEnabled: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Split Here", systemImage: "scissors") {
                    let lifecycle = environment.topicLifecycle
                    let topicID = topicID
                    let utteranceID = utteranceID
                    Task {
                        do {
                            try await lifecycle.split(topicID, atUtterance: utteranceID)
                        } catch {
                            failure = TopicEditFailure.message(for: error)
                        }
                    }
                }
                .disabled(!isEnabled)
                .accessibilityIdentifier(TopicEditAccessibility.split)
            }
            .topicEditFailureAlert($failure)
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

extension View {
    fileprivate func topicEditFailureAlert(_ failure: Binding<String?>) -> some View {
        alert(
            "Couldn't Edit the Topic",
            isPresented: Binding(get: { failure.wrappedValue != nil }, set: { if !$0 { failure.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure.wrappedValue ?? "")
        }
    }
}
