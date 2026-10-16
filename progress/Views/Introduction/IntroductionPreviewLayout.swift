import SwiftUI

/// Gives the video the space left after measuring the heading and subtitle.
struct IntroductionPreviewLayout: Layout {
    let availableHeight: CGFloat
    private let spacing: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let videoSize = videoSize(width: width, textHeight: textSize.height)
        return CGSize(width: width, height: videoSize.height + spacing + textSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let textSize = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let videoSize = videoSize(width: bounds.width, textHeight: textSize.height)

        subviews[0].place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(videoSize)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: bounds.minY + videoSize.height + spacing),
            anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: textSize.height)
        )
    }

    private func videoSize(width: CGFloat, textHeight: CGFloat) -> CGSize {
        let maximumHeight = min(width, 360) * 1.5
        let minimumHeight = min(width, 160) * 1.5
        let height = min(maximumHeight, max(minimumHeight, availableHeight - textHeight - spacing))
        return CGSize(width: height / 1.5, height: height)
    }
}
