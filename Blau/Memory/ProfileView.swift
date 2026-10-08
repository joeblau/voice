import BlauMemory
import BlauPersistence
import SwiftData
import SwiftUI

/// Accessibility identifiers for the profile screens, shared with UI tests.
enum ProfileIdentifiers {
    static let openProfile = "settings.memory.profile"
    static let screen = "memory.profile"
    static let summary = "memory.profile.summary"
    static let budget = "memory.profile.budget"
    static let updateNow = "memory.profile.update"
    static let changes = "memory.profile.changes"
    static let change = "memory.profile.change"
    static let diff = "memory.profile.diff"
}

/// Settings → Memory → Profile (#67): what Blau tells Grok about the user
/// at the start of every conversation, how much of the token budget it
/// uses, and every change sleep-time consolidation made to it, as a diff.
struct ProfileView: View {
    @Environment(ProfileMemory.self) private var profile
    @Environment(MemoryLearningSettings.self) private var learning
    @Query(sort: [SortDescriptor(\ProfileBlock.updatedAt, order: .reverse), SortDescriptor(\ProfileBlock.id)])
    private var blocks: [ProfileBlock]
    @Query(ProfileView.profilePages) private var documents: [MemoryDocument]

    /// The user's `.profile` knowledge-base pages, oldest first.
    static var profilePages: FetchDescriptor<MemoryDocument> {
        let kind = DocumentKind.profile.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
    }

    var body: some View {
        let block = blocks.first { $0.key == ProfileBlock.userKey }
        let pages = userPages
        let pinned = ProfileComposer.standard.pinnedProfile(documents: pages, summary: block?.text)
        List {
            Section {
                if let block, !block.text.isEmpty {
                    Text(block.text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(ProfileIdentifiers.summary)
                } else {
                    Text("Blau hasn't written a profile yet. It writes one from what it learns in your conversations.")
                        .foregroundStyle(.secondary)
                }
                ProfileBudgetRow(tokens: pinned.map(ProfileComposer.tokens) ?? 0)
            } header: {
                Text("Blau's Summary")
            } footer: {
                if let block, block.updatedAt > .distantPast {
                    Text("Updated \(block.updatedAt.formatted(date: .abbreviated, time: .shortened)).")
                }
            }

            if !pages.isEmpty {
                Section {
                    ForEach(pages) { page in
                        VStack(alignment: .leading, spacing: 4) {
                            if !page.title.isEmpty {
                                Text(page.title).font(.headline)
                            }
                            Text(page.body)
                        }
                    }
                } header: {
                    Text("In Your Words")
                } footer: {
                    Text(
                        "Your own profile pages are given to Blau exactly as you wrote them; updates never rewrite them."
                    )
                }
            }

            Section {
                Button {
                    Task { await profile.consolidateNow() }
                } label: {
                    HStack {
                        Label("Update Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if profile.isConsolidating {
                            ProgressView()
                        }
                    }
                }
                .disabled(profile.isConsolidating || !learning.learnsFromConversations)
                .accessibilityIdentifier(ProfileIdentifiers.updateNow)
                if let status = Self.status(profile.lastOutcome) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "About once a week, while your iPhone charges, Blau sends what it has learned to xAI to rewrite "
                        + "this summary and keep it under \(ProfileBlock.tokenBudget.formatted()) tokens. It doesn't "
                        + "run while Learn From Conversations is off."
                )
            }

            Section("Changes") {
                if profile.log.records.isEmpty {
                    Text("No changes yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.log.records) { record in
                    NavigationLink {
                        ProfileChangeView(record: record)
                    } label: {
                        ProfileChangeRow(record: record)
                    }
                    .accessibilityIdentifier(ProfileIdentifiers.change)
                }
            }
            .accessibilityIdentifier(ProfileIdentifiers.changes)
        }
        .accessibilityIdentifier(ProfileIdentifiers.screen)
        .navigationTitle("Profile")
    }

    /// The user's `.profile` pages, one per id: the newest copy, as the
    /// pinned profile reads them.
    private var userPages: [UserProfileDocument] {
        UserProfileDocument.merged(
            documents.filter { $0.kind == .profile }
                .map { UserProfileDocument(id: $0.id, title: $0.title, body: $0.body, updatedAt: $0.updatedAt) })
    }

    static func status(_ outcome: ProfileConsolidationOutcome?) -> String? {
        switch outcome {
        case nil: nil
        case .consolidated: String(localized: "Updated just now.")
        case .unchanged: String(localized: "Already up to date.")
        case .notDue: String(localized: "Nothing new to add yet.")
        case .skipped(.disabled): String(localized: "Learn From Conversations is off.")
        case .skipped(.generatorUnavailable): String(localized: "Add your xAI API key to update the profile.")
        case .skipped(.nothingToConsolidate): String(localized: "Blau hasn't learned anything about you yet.")
        case .skipped(.conflict): String(localized: "Another device just updated the profile.")
        case .skipped(.deferred): String(localized: "Waiting for the device to cool down.")
        case .failed: String(localized: "Couldn't update the profile. Blau will try again later.")
        }
    }
}

/// How much of the token budget the pinned profile uses.
private struct ProfileBudgetRow: View {
    let tokens: Int

    var body: some View {
        let budget = ProfileBlock.tokenBudget
        Gauge(value: Double(min(tokens, budget)), in: 0...Double(budget)) {
            Text("Token Budget")
        } currentValueLabel: {
            Text("\(tokens.formatted()) of \(budget.formatted()) tokens")
        }
        .accessibilityIdentifier(ProfileIdentifiers.budget)
    }
}

private struct ProfileChangeRow: View {
    let record: ProfileConsolidationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
            Text(ProfileChangeView.summary(of: record))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One consolidation's changes: the profile as a word-level diff (added
/// text highlighted, removed text struck through) and the topic summaries
/// it rewrote.
struct ProfileChangeView: View {
    let record: ProfileConsolidationRecord

    var body: some View {
        List {
            Section {
                if record.changedProfile {
                    Self.diffText(record.diff)
                        .textSelection(.enabled)
                        .accessibilityLabel(Self.diffAccessibilityLabel(record.diff))
                        .accessibilityIdentifier(ProfileIdentifiers.diff)
                } else {
                    Text("The summary didn't change.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text(Self.summary(of: record))
            }
            if !record.topicChanges.isEmpty {
                Section("Topic Summaries") {
                    ForEach(record.topicChanges) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.title).font(.headline)
                            Self.diffText(change.diff)
                                .accessibilityLabel(Self.diffAccessibilityLabel(change.diff))
                        }
                    }
                }
            }
            Section("Based On") {
                LabeledContent("Facts", value: record.factCount.formatted())
                LabeledContent("Recent Topics", value: record.topicCount.formatted())
                LabeledContent("Conversation Notes", value: record.noteCount.formatted())
                LabeledContent("Reason", value: Self.reason(record.reason))
            }
        }
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .omitted))
    }

    static func summary(of record: ProfileConsolidationRecord) -> String {
        let diff = record.diff
        var parts: [String] = []
        if record.changedProfile {
            parts.append(
                String(localized: "\(diff.addedWordCount) words added, \(diff.removedWordCount) removed"))
            parts.append(String(localized: "\(record.tokenCount) tokens"))
        }
        if !record.topicChanges.isEmpty {
            parts.append(String(localized: "\(record.topicChanges.count) topic summaries"))
        }
        return parts.joined(separator: " · ")
    }

    static func reason(_ reason: ProfileConsolidationReason) -> String {
        switch reason {
        case .firstRun: String(localized: "First profile")
        case .weekly: String(localized: "Weekly update")
        case .newFacts: String(localized: "New facts")
        case .removedFacts: String(localized: "Facts removed")
        case .manual: String(localized: "You asked")
        }
    }

    /// The diff as one text: added runs tinted and underlined, removed runs
    /// struck through, so the change reads without color too.
    static func diffText(_ diff: ProfileDiff) -> Text {
        var text = AttributedString()
        for segment in diff.segments {
            var run = AttributedString(segment.text)
            switch segment.change {
            case .unchanged:
                break
            case .added:
                run.foregroundColor = .green
                run.underlineStyle = .single
            case .removed:
                run.foregroundColor = .red
                run.strikethroughStyle = .single
            }
            text += run
        }
        return Text(text)
    }

    /// The diff read aloud: VoiceOver can't hear color or strikethrough.
    static func diffAccessibilityLabel(_ diff: ProfileDiff) -> String {
        diff.segments
            .map { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch segment.change {
                case .unchanged: return text
                case .added: return String(localized: "added: \(text)")
                case .removed: return String(localized: "removed: \(text)")
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

#if DEBUG
    #Preview("Profile change") {
        NavigationStack {
            ProfileChangeView(
                record: ProfileConsolidationRecord(
                    date: Date(), reason: .weekly,
                    before: "Work: The user works at Stripe.\n\nGoals: Ship Blau.",
                    after: "Work: The user runs Acme Robotics with Dana.\n\nGoals: Ship Blau and raise a seed round.",
                    topicChanges: [
                        TopicSummaryChange(
                            topicID: UUID(), title: "Seed Round", before: "They talk about money.",
                            after: "Joe and Dana plan the Acme seed round.")
                    ], factCount: 42, noteCount: 3, topicCount: 12))
        }
    }
#endif
