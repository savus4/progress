import SwiftUI

struct TimelineNavigationTitle: View {
    let title: String
    var timelineID: UUID?
    var transition: AnyTransition = .opacity
    var animation: Animation?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var topSpacing: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(timelineID)
                .transition(transition)
        }
        .clipped()
        .animation(animation ?? .easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: title)
        .padding(.top, title.isEmpty ? 0 : topSpacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(title.isEmpty)
    }
}
