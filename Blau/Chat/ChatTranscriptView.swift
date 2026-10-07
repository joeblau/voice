import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import SwiftData
import SwiftUI

/// The accessibility identifiers UI tests use for the chat transcript.
enum ChatTranscriptAccessibility {
    /// The transcript's rows, inside the main screen's scroll view
    /// (`MainScreenAccessibility.content`).
    static let transcript = "blau.chat"
    /// A finished user utterance (right-aligned).
    static let userRow = "blau.chat.user"
    /// A finished agent utterance (left-aligned).
    static let agentRow = "blau.chat.agent"
    /// The user's speech in progress.
    static let partialRow = "blau.chat.user.partial"
    /// Grok's reply while it plays.
    static let streamingRow = "blau.chat.agent.streaming"
    /// A note from the app (centered).
    static let systemRow = "blau.chat.system"
    /// A tool Grok called, as a chip (centered), e.g. "Searched memory".
    static let toolRow = "blau.chat.tool"
}

/// Layout constants of the transcript.
enum ChatTranscriptLayout {
    /// A row is at most this share of the transcript's width, so a line of
    /// text never runs from edge to edge and the alignment reads at a
    /// glance.
    static let maxWidthFraction: CGFloat = 0.85
    /// Space between rows.
    static let rowSpacing: CGFloat = 14
    /// How close to the end counts as "at the bottom": new rows then keep
    /// the transcript pinned to the latest line.
    static let bottomThreshold: CGFloat = 48
}

/// The conversation (#42): what the user said right-aligned, what Grok said
/// left-aligned, with no bubbles. Rows differ by alignment, weight and color
/// only.
///
/// Finished rows come from the store (`@Query` on conversation
/// `conversationID`), updated by the utterances the app just wrote
/// (`ChatTranscriptModel.recorded`); below them the live rows show the
/// user's speech in progress and Grok's reply as it plays.
///
/// A lazy stack in a bottom-anchored scroll view (not an inverted one):
/// only the rows on screen are built, so a 1,000-row conversation scrolls
/// as smoothly as a short one. While the user is at the bottom, new rows
/// and growing replies keep it there; scrolled up into history, the
/// reading position holds.
struct ChatTranscriptView: View {
    let conversationID: UUID
    /// Opens the xAI key onboarding step. Its button follows the rows while
    /// no usable key is stored.
    var onConnectAccount: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @State private var isAtBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ChatTranscriptLayout.rowSpacing) {
                ChatFinishedRows(conversationID: conversationID, model: environment.chat)
                ChatLiveRows(model: environment.chat)
                if let onConnectAccount, environment.xai.account.needsKeyEntry {
                    Button("Connect Your xAI Account", action: onConnectAccount)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(XAIKeyIdentifiers.openOnboarding)
                        .padding(.top)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ChatTranscriptAccessibility.transcript)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Pinned to the latest line only while the user is there.
        .defaultScrollAnchor(isAtBottom ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
            return visibleBottom >= geometry.contentSize.height - ChatTranscriptLayout.bottomThreshold
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
    }
}

/// The stored rows of one conversation. Rebuilt when the store, the
/// just-written utterances or the set of playing replies change, never for
/// a single word of a reply or partial.
private struct ChatFinishedRows: View {
    let conversationID: UUID
    let model: ChatTranscriptModel
    @Query private var utterances: [StoredUtterance]

    init(conversationID: UUID, model: ChatTranscriptModel) {
        self.conversationID = conversationID
        self.model = model
        _utterances = Query(ChatTranscript.utterances(in: conversationID))
    }

    var body: some View {
        let rows = ChatTranscript.rows(
            stored: utterances.compactMap(ChatLine.init),
            // The model's lines belong to the running conversation; when
            // another one is on screen they don't apply.
            recorded: isLiveConversation ? model.recorded : [:],
            excluding: isLiveConversation ? model.liveAgentIDs : [],
            interrupted: isLiveConversation ? model.interruptedAgentIDs : [],
            waiting: isLiveConversation ? model.waitingUserIDs : [],
            notSent: isLiveConversation ? model.unsentUserIDs : [],
            // Tool chips live in memory for the running conversation only.
            toolCalls: isLiveConversation ? model.finishedToolCalls : [])
        ForEach(rows) { row in
            ChatRowView(row: row)
        }
    }

    private var isLiveConversation: Bool {
        model.conversationID?.rawValue == conversationID
    }
}

/// The rows below the finished ones: Grok's reply as it plays, then the
/// user's speech in progress.
private struct ChatLiveRows: View {
    let model: ChatTranscriptModel

    var body: some View {
        ForEach(model.liveRows) { row in
            ChatRowView(row: row, progress: model.progress)
        }
    }
}

// MARK: - Rows

/// One utterance: plain text, aligned to its speaker's side, at most 85 % of
/// the width. No background.
struct ChatRowView: View {
    let row: ChatRow
    /// Reveals a streaming reply in step with its audio.
    var progress: ChatPlaybackProgress?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let call = row.toolCall {
            ChatToolChip(call: call)
        } else {
            utterance
        }
    }

    private var utterance: some View {
        // The element, and what the long-press lifts, is the text itself;
        // the frames around it only place it.
        VStack(alignment: .trailing, spacing: 2) {
            text
                .multilineTextAlignment(textAlignment)
            if row.role == .user, row.delivery != .sent {
                ChatDeliveryNote(delivery: row.delivery)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speakerLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .modifier(ChatRowMenu(row: row))
        .containerRelativeFrame(.horizontal, alignment: frameAlignment) { length, _ in
            row.role == .system ? length : length * ChatTranscriptLayout.maxWidthFraction
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private var text: some View {
        switch row.kind {
        case .final:
            // The second pass (#30) rewrites a final row's text in place
            // (docs/asr.md): morph to the new words, unless Reduce Motion
            // is on.
            ChatRowText(row: row, text: row.text)
                .contentTransition(.interpolate)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: row.text)
        case .partial, .tool:
            ChatRowText(row: row, text: row.text)
        case .streaming(let item):
            if let progress {
                // A few times a second is enough for words; only this row
                // is redrawn.
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    ChatRowText(row: row, text: ChatTranscript.revealedText(of: row.text, played: progress(item)))
                }
            } else {
                ChatRowText(row: row, text: row.text)
            }
        }
    }

    private var textAlignment: TextAlignment {
        switch row.role {
        case .user: .trailing
        case .agent: .leading
        case .system: .center
        }
    }

    private var frameAlignment: Alignment {
        switch row.role {
        case .user: .trailing
        case .agent: .leading
        case .system: .center
        }
    }

    private var speakerLabel: Text {
        switch row.role {
        case .user: Text("You")
        case .agent: Text("Grok")
        case .system: Text("Blau")
        }
    }

    private var accessibilityValue: Text {
        switch (row.kind, row.isInterrupted, row.delivery) {
        case (.partial, _, _): Text("\(row.text), still speaking")
        case (_, true, _): Text("\(row.text), interrupted")
        case (_, _, .waiting): Text("\(row.text), waiting to send")
        case (_, _, .notSent): Text("\(row.text), not sent")
        default: Text(verbatim: row.text)
        }
    }

    private var accessibilityIdentifier: String {
        switch (row.role, row.kind) {
        case (.user, .partial): ChatTranscriptAccessibility.partialRow
        case (.user, _): ChatTranscriptAccessibility.userRow
        case (.agent, .streaming): ChatTranscriptAccessibility.streamingRow
        case (.agent, _): ChatTranscriptAccessibility.agentRow
        case (.system, _): ChatTranscriptAccessibility.systemRow
        }
    }
}

/// A row's text in its speaker's style: the user's in the accent color and
/// a heavier weight, Grok's in the primary color, speech in progress in the
/// secondary color, and an interrupted reply ending in a faint dash.
private struct ChatRowText: View {
    let row: ChatRow
    let text: String

    @ViewBuilder
    var body: some View {
        switch (row.role, row.kind) {
        case (.user, .partial):
            Text(verbatim: text)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        case (.user, _):
            Text(verbatim: text)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
        case (.agent, _):
            if row.isInterrupted {
                // A thin space and an em dash: the reply was cut off here.
                Text("\(Text(verbatim: text))\(Text(verbatim: "\u{2009}\u{2014}").foregroundStyle(.tertiary))")
                    .font(.body)
                    .foregroundStyle(.primary)
            } else {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        case (.system, _):
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Under a user row that hasn't reached Grok (#80): "Waiting to send" while
/// offline, "Not sent" once discarded. Part of the row's accessibility value,
/// so hidden from VoiceOver here.
private struct ChatDeliveryNote: View {
    let delivery: ChatRow.Delivery

    var body: some View {
        Group {
            switch delivery {
            case .waiting: Label("Waiting to send", systemImage: "clock")
            case .notSent: Label("Not sent", systemImage: "xmark.circle")
            case .sent: EmptyView()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// A tool Grok called (#68): a small, quiet capsule in the middle of the
/// transcript, "Searched memory". In DEBUG builds it opens the call's
/// arguments and output.
struct ChatToolChip: View {
    let call: ChatToolCall

    @State private var showsPayload = false

    var body: some View {
        chip
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Blau"))
            .accessibilityValue(Text(verbatim: call.title))
            .accessibilityIdentifier(ChatTranscriptAccessibility.toolRow)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var chip: some View {
        #if DEBUG
            if let payload = call.payload {
                Button {
                    showsPayload = true
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows what Grok asked and what memory answered"))
                .sheet(isPresented: $showsPayload) {
                    ChatToolPayloadView(title: call.title, payload: payload)
                }
            } else {
                label
            }
        #else
            label
        #endif
    }

    private var label: some View {
        Label {
            Text(verbatim: call.title)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(.quaternary))
    }

    private var symbol: String {
        switch call.state {
        case .failed: "exclamationmark.circle"
        case .running, .succeeded: MemoryTools.names.contains(call.name) ? "brain" : "wrench.and.screwdriver"
        }
    }
}

#if DEBUG
    /// The full payload of a tool call: what Grok sent and what it got back.
    private struct ChatToolPayloadView: View {
        let title: String
        let payload: String

        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(verbatim: Self.prettyPrinted(payload))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        /// Each line's JSON pretty-printed, the rest as it is.
        static func prettyPrinted(_ payload: String) -> String {
            payload.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                guard let colon = line.firstIndex(of: ":") else { return String(line) }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let data = value.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data),
                    let pretty = try? JSONSerialization.data(
                        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                else { return String(line) }
                return "\(line[..<colon]):\n\(String(decoding: pretty, as: UTF8.self))"
            }
            .joined(separator: "\n")
        }
    }
#endif

/// Long-press menu of a finished row: when it was said, Copy and Share.
private struct ChatRowMenu: ViewModifier {
    let row: ChatRow

    func body(content: Content) -> some View {
        if row.kind == .final {
            content.contextMenu {
                Section {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = row.text
                    }
                    ShareLink(item: row.text)
                } header: {
                    Text(row.startedAt, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Transcript") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        ChatTranscriptPreview()
    }
    .appEnvironment(environment)
    .task { await ChatTranscriptFixture.seed(count: 40, into: environment.persistence) }
}

#Preview("Rows") {
    let now = Date()
    ScrollView {
        LazyVStack(spacing: ChatTranscriptLayout.rowSpacing) {
            ChatRowView(
                row: ChatRow(id: UUID(), role: .user, text: "What should I focus on this week?", startedAt: now))
            ChatRowView(
                row: ChatRow(
                    tool: ChatToolCall(
                        id: "call_1", name: "search_memory", startedAt: now, state: .succeeded,
                        arguments: #"{"query":"this week's priorities"}"#, output: #"{"results":[]}"#)))
            ChatRowView(
                row: ChatRow(
                    id: UUID(), role: .agent,
                    text: "Start with the launch checklist, then block two mornings for customer calls.",
                    startedAt: now))
            ChatRowView(
                row: ChatRow(
                    id: UUID(), role: .agent, text: "The Golden Gate Bridge opened in", startedAt: now,
                    isInterrupted: true))
            ChatRowView(
                row: ChatRow(id: UUID(), role: .user, text: "Actually, just the year", startedAt: now, kind: .partial)
            )
        }
        .padding()
    }
}

/// The latest conversation in the preview store.
private struct ChatTranscriptPreview: View {
    @Query(ChatTranscript.latestConversation) private var conversations: [Conversation]

    var body: some View {
        if let conversation = conversations.first {
            ChatTranscriptView(conversationID: conversation.id)
        }
    }
}
