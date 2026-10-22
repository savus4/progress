import SwiftUI

/// Content-sized chips retain their reading order and wrap at the available width.
struct TimelineFlowLayout: Layout {
    var spacing: CGFloat = 8
    var layoutDirection: LayoutDirection = .leftToRight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            let x = layoutDirection == .rightToLeft ? bounds.maxX - frame.maxX : bounds.minX + frame.minX
            subview.place(at: CGPoint(x: x, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, proposedWidth ?? .greatestFiniteMagnitude)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: proposedWidth ?? contentWidth, height: y + rowHeight), frames)
    }
}
