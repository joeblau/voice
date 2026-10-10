import SwiftUI

/// Lays out one set of action controls, horizontally when their ideal
/// widths fit and vertically otherwise. Unlike two ViewThatFits candidates,
/// it does not build a second ShareLink, menu and button graph on expansion.
/// Cached sizes are reused during placement instead of measuring the same
/// controls through two type-erased stack layouts.
struct TopicActionsLayout: Layout {
    @Environment(\.layoutDirection) private var layoutDirection
    private let spacing: CGFloat = 8

    struct Cache {
        var idealSizes: [CGSize]
        var sizes: [CGSize] = []
        var proposedWidth: CGFloat?
        var hasMeasured = false
        var stacksVertically = false
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(width: proposal.width, subviews: subviews, cache: &cache)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: proposal.width, subviews: subviews, cache: &cache)
        let isRightToLeft = layoutDirection == .rightToLeft
        var offset: CGFloat = 0
        for (subview, size) in zip(subviews, cache.sizes) {
            let horizontalOffset = cache.stacksVertically ? 0 : offset
            let x =
                isRightToLeft
                ? bounds.maxX - horizontalOffset - size.width / 2
                : bounds.minX + horizontalOffset + size.width / 2
            let y = cache.stacksVertically ? bounds.minY + offset + size.height / 2 : bounds.midY
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .center,
                proposal: ProposedViewSize(size))
            offset += (cache.stacksVertically ? size.height : size.width) + spacing
        }
    }

    private func measure(width: CGFloat?, subviews: Subviews, cache: inout Cache) {
        guard !cache.hasMeasured || cache.proposedWidth != width else { return }
        let gaps = CGFloat(max(0, subviews.count - 1)) * spacing
        let idealWidth = cache.idealSizes.reduce(0) { $0 + $1.width } + gaps
        cache.stacksVertically = width.map { idealWidth > $0 } ?? false
        if cache.stacksVertically, let width {
            cache.sizes = zip(subviews, cache.idealSizes).map { subview, ideal in
                subview.sizeThatFits(ProposedViewSize(width: max(0, min(width, ideal.width)), height: nil))
            }
            cache.size = CGSize(
                width: cache.sizes.map(\.width).max() ?? 0,
                height: cache.sizes.reduce(0) { $0 + $1.height } + gaps)
        } else {
            cache.sizes = cache.idealSizes
            cache.size = CGSize(width: idealWidth, height: cache.sizes.map(\.height).max() ?? 0)
        }
        cache.proposedWidth = width
        cache.hasMeasured = true
    }
}
