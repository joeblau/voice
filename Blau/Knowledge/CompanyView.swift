import BlauPersistence
import SwiftData
import SwiftUI

/// Settings → Knowledge → Company (#65): the user's company as structured
/// fields plus free text, stored as the knowledge base's `.company`
/// document (`CompanyProfile` lays the fields out as Markdown sections).
/// Grok reads it for "what does my company do?" (`search_memory`,
/// `kinds: ["company"]`).
struct CompanyView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(MemoryDocument.pages(of: .company))
    private var companies: [MemoryDocument]

    var body: some View {
        let stored = companies.first
        CompanyEditor(
            draft: KnowledgeDraft(
                kind: .company, documentID: stored?.id ?? UUID(), title: stored?.title ?? "",
                body: stored?.body ?? "", editor: environment.knowledgeBase, clock: environment.clock),
            stored: stored)
    }
}

extension CompanyProfile.Field {
    /// The field's label on the page (the stored heading is fixed English).
    var label: String {
        switch self {
        case .oneLiner: String(localized: "What It Does")
        case .product: String(localized: "Product")
        case .customers: String(localized: "Customers and Market")
        case .businessModel: String(localized: "Business Model")
        case .traction: String(localized: "Traction")
        case .team: String(localized: "Team")
        case .funding: String(localized: "Funding")
        case .website: String(localized: "Website")
        }
    }

    var prompt: String {
        switch self {
        case .oneLiner: String(localized: "One sentence: what you make and for whom")
        case .product: String(localized: "How it works, what's built")
        case .customers: String(localized: "Who buys it, how many of them there are")
        case .businessModel: String(localized: "How you make money, pricing")
        case .traction: String(localized: "Users, revenue, growth")
        case .team: String(localized: "Founders and who does what")
        case .funding: String(localized: "Raised so far, from whom, what's next")
        case .website: String(localized: "example.com")
        }
    }
}

private struct CompanyEditor: View {
    @State var draft: KnowledgeDraft
    let stored: MemoryDocument?
    @State private var company: CompanyProfile

    init(draft: KnowledgeDraft, stored: MemoryDocument?) {
        _draft = State(initialValue: draft)
        self.stored = stored
        _company = State(initialValue: CompanyProfile(name: draft.title, markdown: draft.body))
    }

    private static let detailFields: [CompanyProfile.Field] = [
        .product, .customers, .businessModel, .traction, .team, .funding,
    ]

    var body: some View {
        Form {
            Section("Company") {
                TextField("Name", text: $company.name)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.companyName)
                field(.oneLiner)
            }
            Section("Details") {
                ForEach(Self.detailFields, id: \.self) { field($0) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(CompanyProfile.Field.website.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(CompanyProfile.Field.website.prompt, text: $company[.website])
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(CompanyProfile.Field.website.label)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.companyField(.website))
                }
            }
            Section {
                TextField("Anything else worth knowing. Markdown is fine.", text: $company.notes, axis: .vertical)
                    .lineLimit(5...)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.companyNotes)
            } header: {
                Text("Notes")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grok looks this up when you ask about your company, product, customers or traction.")
                    KnowledgeSaveStatus(draft: draft)
                }
            }
        }
        .navigationTitle("Company")
        .onChange(of: company) {
            draft.title = company.name
            draft.body = company.markdown
        }
        .onChange(of: draft.revision) {
            // Synced from another device: show its text.
            company = CompanyProfile(name: draft.title, markdown: draft.body)
        }
        .knowledgeDraft(draft, stored: stored)
    }

    private func field(_ field: CompanyProfile.Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(field.prompt, text: $company[field], axis: .vertical)
                .lineLimit(1...8)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.companyField(field))
        }
    }
}

#if DEBUG
    #Preview("Company") {
        let environment = AppEnvironment.preview()
        NavigationStack {
            CompanyView()
        }
        .appEnvironment(environment)
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
