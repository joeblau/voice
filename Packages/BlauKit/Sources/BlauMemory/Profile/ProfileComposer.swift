import BlauPersistence
import Foundation

/// Keeps the pinned profile inside its token budget (#67).
///
/// What Blau pins to the start of every realtime session is two parts:
///
/// 1. **The user's own words**: the `.profile` knowledge-base pages the
///    user wrote, verbatim. Consolidation never rewrites them; it is only
///    cut, at a paragraph, sentence or word boundary and marked with "…",
///    when it alone would take more than `userAuthoredShare` of the budget
///    (the rest stays searchable through memory search).
/// 2. **The consolidated summary**: the `ProfileBlock` text the
///    consolidation model writes from facts and recent topics, in the
///    budget the first part leaves.
///
/// The user's words are composed at read time, not stored in the block, so
/// an edit reaches the next session at once and can never be paraphrased.
///
/// Tokens are `ProfileBlock.approximateTokenCount`'s estimate (UTF-8 bytes
/// / 4, rounded up), so the budget is checked in bytes: a text is within
/// `tokenBudget` exactly when it has at most `tokenBudget * 4` bytes.
public struct ProfileComposer: Hashable, Sendable {
    /// The most tokens the pinned profile may take.
    public var tokenBudget: Int
    /// The largest share of the budget the user's own words may take while
    /// there is a summary to pin too.
    public var userAuthoredShare: Double

    public init(tokenBudget: Int = ProfileBlock.tokenBudget, userAuthoredShare: Double = 0.6) {
        self.tokenBudget = max(0, tokenBudget)
        self.userAuthoredShare = min(max(userAuthoredShare, 0), 1)
    }

    public static let standard = ProfileComposer()

    /// The line that opens the user's own words.
    public static let userAuthoredHeading = "In the user's own words:"

    /// Marks where verbatim text was cut.
    public static let ellipsis = "…"

    static let separator = "\n\n"

    /// `ProfileBlock.approximateTokenCount` for `text`.
    public static func tokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// The budget in UTF-8 bytes.
    public var byteBudget: Int { tokenBudget * 4 }

    // MARK: Composing

    /// The profile pinned to a session: the user's own words, then the
    /// consolidated summary, within `tokenBudget`. `nil` when both are
    /// empty.
    public func pinnedProfile(documents: [UserProfileDocument], summary: String?) -> String? {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = userSection(documents, leavingRoomForSummary: !summary.isEmpty)
        let fitted = Self.fitted(summary, maximumBytes: summaryByteBudget(after: user))
        let composed = [user, fitted].filter { !$0.isEmpty }.joined(separator: Self.separator)
        return composed.isEmpty ? nil : composed
    }

    /// The user's `.profile` pages, verbatim, under `userAuthoredHeading`.
    /// Empty when there are none. Cut to `userAuthoredShare` of the budget
    /// when a summary has to fit too, otherwise to the whole budget.
    public func userSection(_ documents: [UserProfileDocument], leavingRoomForSummary: Bool = true) -> String {
        let pages =
            documents
            .map { document -> String in
                let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return body }
                guard !body.isEmpty else { return "" }
                return "\(title):\n\(body)"
            }
            .filter { !$0.isEmpty }
        guard !pages.isEmpty else { return "" }
        let full = ([Self.userAuthoredHeading] + pages).joined(separator: "\n")
        let limit = leavingRoomForSummary ? Int(Double(byteBudget) * userAuthoredShare) : byteBudget
        if full.utf8.count <= limit {
            return full
        }
        let heading = Self.userAuthoredHeading + "\n"
        let room = limit - heading.utf8.count - Self.ellipsis.utf8.count
        guard room > 0 else { return "" }
        let body = String(full.dropFirst(heading.count))
        let cut = Self.prefix(of: body, maximumBytes: room).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cut.isEmpty else { return "" }
        return heading + cut + Self.ellipsis
    }

    /// The bytes left for the consolidated summary after `userSection`.
    public func summaryByteBudget(after userSection: String) -> Int {
        guard !userSection.isEmpty else { return byteBudget }
        return max(0, byteBudget - userSection.utf8.count - Self.separator.utf8.count)
    }

    /// The tokens left for the consolidated summary after `userSection`.
    public func summaryTokenBudget(after userSection: String) -> Int {
        summaryByteBudget(after: userSection) / 4
    }

    /// About how many words fit in `bytes` of English prose, for telling
    /// the model its length. Deliberately low (7 bytes a word), so a reply
    /// rarely has to be cut.
    public static func wordBudget(forBytes bytes: Int) -> Int {
        max(0, bytes / 7)
    }

    // MARK: Fitting

    /// `text` cut to at most `maximumBytes` UTF-8 bytes, at the last line
    /// break, else the last sentence end, else the last space that fits,
    /// so a model's overlong reply loses whole thoughts from the end rather
    /// than half a word.
    public static func fitted(_ text: String, maximumBytes: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count > maximumBytes else { return text }
        return prefix(of: text, maximumBytes: maximumBytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The longest prefix of `text` within `maximumBytes` that ends at a
    /// line break, a sentence end or a space, preferring the coarsest
    /// boundary that keeps at least half of what fits. Falls back to a
    /// character boundary.
    static func prefix(of text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            let size = text[index].utf8.count
            guard used + size <= maximumBytes else { break }
            used += size
            end = text.index(after: index)
        }
        let fits = text[..<end]
        guard end < text.endIndex else { return String(fits) }
        let half = used / 2
        let boundaries: [(Character) -> Bool] = [
            { $0.isNewline },
            { ".!?".contains($0) },
            { $0.isWhitespace },
        ]
        for isBoundary in boundaries {
            guard let index = fits.lastIndex(where: isBoundary) else { continue }
            // Keep a sentence's closing punctuation; drop a trailing break.
            let cut = fits[index].isWhitespace ? fits[..<index] : fits[...index]
            if cut.utf8.count >= half {
                return String(cut)
            }
        }
        return String(fits)
    }
}
