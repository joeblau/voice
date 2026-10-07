import BlauMemory
import BlauPersistence
import SwiftData
import SwiftUI
import os

/// Accessibility identifiers for Settings → Memory, shared with UI tests.
enum MemorySettingsIdentifiers {
    static let learnToggle = "settings.memory.learn"
    static let openLearned = "settings.memory.learned"
    static let learnedList = "memory.learned.list"
    static let emptyState = "memory.learned.empty"
}

/// Settings → Memory (#66): whether Blau learns from conversations, and
/// what it has learned.
struct MemorySettingsSection: View {
    @Environment(MemoryLearningSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Learn From Conversations", isOn: $settings.learnsFromConversations)
                .accessibilityIdentifier(MemorySettingsIdentifiers.learnToggle)
            NavigationLink {
                LearnedFactsView()
            } label: {
                Label("What Blau Learned", systemImage: "brain")
            }
            .accessibilityIdentifier(MemorySettingsIdentifiers.openLearned)
        } header: {
            Text("Memory")
        } footer: {
            Text(
                "After each topic, Blau sends its transcript to xAI to pick out facts worth remembering, like "
                    + "where you work or who you mention. Turn this off to stop learning; what Blau already "
                    + "learned stays until you delete it."
            )
        }
    }
}

/// "What Blau Learned": every fact memory holds, current ones first, with
/// swipe to delete. Facts that stopped being true stay listed (memory is
/// add-only and keeps their history) until the user deletes them.
///
/// Reads with `@Query`; deletes through the app's `MemoryLearning`, which
/// writes off the main thread like every other store write.
struct LearnedFactsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\Fact.createdAt, order: .reverse), SortDescriptor(\Fact.validFrom, order: .reverse)])
    private var facts: [Fact]
    @State private var failure: String?

    var body: some View {
        let rows = Self.rows(facts)
        List {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing Learned Yet",
                    systemImage: "brain",
                    description: Text("Facts Blau picks up from your conversations show up here.")
                )
                .accessibilityIdentifier(MemorySettingsIdentifiers.emptyState)
            }
            let current = rows.filter(\.isCurrent)
            let past = rows.filter { !$0.isCurrent }
            if !current.isEmpty {
                Section("Current") {
                    ForEach(current) { LearnedFactRow(fact: $0) }
                        .onDelete { forget(current, at: $0) }
                }
            }
            if !past.isEmpty {
                Section("No Longer True") {
                    ForEach(past) { LearnedFactRow(fact: $0) }
                        .onDelete { forget(past, at: $0) }
                }
            }
        }
        .accessibilityIdentifier(MemorySettingsIdentifiers.learnedList)
        .navigationTitle("What Blau Learned")
        .alert(
            "Couldn't Delete",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func forget(_ rows: [Row], at offsets: IndexSet) {
        let ids = offsets.map { rows[$0].id }
        let learning = environment.memoryLearning
        Task {
            do {
                for id in ids {
                    try await learning.forget(id)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// One row per fact id: CloudKit can hold two copies of a fact, and the
    /// earliest invalidation wins.
    static func rows(_ facts: [Fact]) -> [Row] {
        var order: [UUID] = []
        var byID: [UUID: Row] = [:]
        for fact in facts {
            if var existing = byID[fact.id] {
                if let invalidatedAt = fact.invalidatedAt {
                    existing.invalidatedAt = min(existing.invalidatedAt ?? invalidatedAt, invalidatedAt)
                    byID[fact.id] = existing
                }
                continue
            }
            order.append(fact.id)
            byID[fact.id] = Row(
                id: fact.id, statement: fact.statement(userName: String(localized: "You")),
                validFrom: fact.validFrom, invalidatedAt: fact.invalidatedAt, origin: fact.origin)
        }
        return order.compactMap { byID[$0] }
    }

    struct Row: Identifiable, Hashable {
        let id: UUID
        let statement: String
        let validFrom: Date
        var invalidatedAt: Date?
        let origin: FactOrigin?

        var isCurrent: Bool { invalidatedAt == nil }
    }
}

private struct LearnedFactRow: View {
    let fact: LearnedFactsView.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fact.statement)
                .foregroundStyle(fact.isCurrent ? .primary : .secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let since = fact.validFrom.formatted(date: .abbreviated, time: .omitted)
        let source = fact.origin == .user ? String(localized: "You told Blau") : String(localized: "Learned")
        if let until = fact.invalidatedAt {
            let end = until.formatted(date: .abbreviated, time: .omitted)
            return "\(source) · \(since) – \(end)"
        }
        return "\(source) · since \(since)"
    }
}

#if DEBUG
    #Preview("Memory settings") {
        let environment = AppEnvironment.preview()
        NavigationStack {
            Form {
                MemorySettingsSection()
            }
        }
        .appEnvironment(environment)
    }
#endif
