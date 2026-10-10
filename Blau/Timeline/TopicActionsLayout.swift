import SwiftUI

/// Lays out one set of action controls, horizontally when their ideal
/// widths fit and vertically otherwise. Unlike two ViewThatFits candidates,
/// it does not build a second ShareLink, menu and button graph on expansion.
struct TopicActionsLayout: Layout {
    private let horizontal = AnyLayout(HStackLayout(spacing: 8))
    private let vertical = AnyLayout(VStackLayout(alignment: .leading, spacing: 8))

    struct Cache {
        var horizontal: AnyLayout.Cache
        var vertical: AnyLayout.Cache
        var stacksVertically = false
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(
            horizontal: horizontal.makeCache(subviews: subviews),
            vertical: vertical.makeCache(subviews: subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        horizontal.updateCache(&cache.horizontal, subviews: subviews)
        vertical.updateCache(&cache.vertical, subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ideal = horizontal.sizeThatFits(
            proposal: .unspecified, subviews: subviews, cache: &cache.horizontal)
        cache.stacksVertically = proposal.width.map { ideal.width > $0 } ?? false
        if cache.stacksVertically {
            return vertical.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache.vertical)
        }
        return horizontal.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache.horizontal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.stacksVertically {
            vertical.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache.vertical)
        } else {
            horizontal.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache.horizontal)
        }
    }
}
