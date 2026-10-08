import Foundation

/// The company page of the knowledge base (#65): structured fields plus free
/// text, stored as one `.company` `Document`.
///
/// The schema has no columns for the fields (and adding them would be a
/// CloudKit schema change), so they live in the document's Markdown body, one
/// `## Heading` per filled-in field, in a fixed order:
///
/// ```markdown
/// ## What It Does
/// Inventory and food-cost app for independent restaurants.
///
/// ## Traction
/// 40 paying restaurants, $18k MRR.
///
/// ## Notes
/// Anything else, Markdown allowed.
/// ```
///
/// That keeps the page readable anywhere the body shows up (search results,
/// the Markdown export) and lets the memory index cut it at the headings, so
/// each field is its own chunk keyed `[Larderly] [Traction] …` (see
/// docs/memory-index.md). The company's name is the document's title.
///
/// `init(name:markdown:)` reads a body back. Text under a heading that isn't
/// one of the fields, or before the first heading, is kept in `notes`, so
/// nothing typed on another device (or by an older or newer app version) is
/// ever dropped.
public struct CompanyProfile: Hashable, Sendable {
    /// One structured field, in the order the page shows and stores them.
    public enum Field: String, CaseIterable, Hashable, Sendable {
        case oneLiner
        case product
        case customers
        case businessModel
        case traction
        case team
        case funding
        case website

        /// The `##` heading the field is stored under. Fixed English text:
        /// it is part of the stored format, so it must not be localized.
        public var heading: String {
            switch self {
            case .oneLiner: "What It Does"
            case .product: "Product"
            case .customers: "Customers and Market"
            case .businessModel: "Business Model"
            case .traction: "Traction"
            case .team: "Team"
            case .funding: "Funding"
            case .website: "Website"
            }
        }
    }

    /// The heading free text is stored under.
    public static let notesHeading = "Notes"

    /// The company's name: the document's title.
    public var name: String
    /// The structured fields. A missing or blank value isn't stored.
    public var fields: [Field: String]
    /// Free text, Markdown allowed.
    public var notes: String

    public init(name: String = "", fields: [Field: String] = [:], notes: String = "") {
        self.name = name
        self.fields = fields
        self.notes = notes
    }

    public subscript(field: Field) -> String {
        get { fields[field] ?? "" }
        set { fields[field] = newValue }
    }

    /// Whether nothing at all is filled in.
    public var isEmpty: Bool {
        name.trimmed.isEmpty && notes.trimmed.isEmpty && fields.values.allSatisfy(\.trimmed.isEmpty)
    }

    /// The document body: each filled-in field under its heading, then the
    /// notes under `## Notes`. Values are trimmed; blank ones are left out.
    public var markdown: String {
        var sections: [String] = []
        for field in Field.allCases {
            let value = self[field].trimmed
            guard !value.isEmpty else { continue }
            sections.append("## \(field.heading)\n\(value)")
        }
        let notes = notes.trimmed
        if !notes.isEmpty {
            sections.append("## \(Self.notesHeading)\n\(notes)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Reads a company document back: `name` is its title, `markdown` its
    /// body.
    ///
    /// A level-2 heading that names a field (any case, surrounding spaces
    /// ignored) starts that field; everything else (text before the first
    /// heading, `## Notes`, any other heading with its text) goes to
    /// `notes`, unknown headings included, in the order it appears. A field
    /// that appears twice keeps both parts.
    public init(name: String, markdown: String) {
        self.name = name
        var fields: [Field: [String]] = [:]
        var notes: [String] = []
        // Where the lines being read go: a field, or the notes.
        var current: Field?
        var buffer: [String] = []
        var inFence = false

        func flush() {
            let text = buffer.joined(separator: "\n").trimmed
            buffer.removeAll()
            guard !text.isEmpty else { return }
            if let current {
                fields[current, default: []].append(text)
            } else {
                notes.append(text)
            }
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            }
            guard !inFence, let heading = Self.levelTwoHeading(line) else {
                buffer.append(line)
                continue
            }
            flush()
            if let field = Self.field(forHeading: heading) {
                current = field
            } else {
                current = nil
                if heading.caseInsensitiveCompare(Self.notesHeading) != .orderedSame {
                    // Someone else's section: keep it, heading and all.
                    buffer.append(line)
                }
            }
        }
        flush()

        self.fields = fields.mapValues { $0.joined(separator: "\n\n") }
        self.notes = notes.joined(separator: "\n\n")
    }

    /// The text of a `## Heading` line, or `nil` for any other line.
    static func levelTwoHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), !trimmed.hasPrefix("###") else { return nil }
        var text = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        // A closing sequence of #s is allowed in ATX headings.
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func field(forHeading heading: String) -> Field? {
        Field.allCases.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
