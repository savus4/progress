import SwiftUI

struct IntroductionPageContainer<Content: View>: View {
    private let alignment: Alignment
    private let content: (CGFloat) -> Content

    init(alignment: Alignment = .bottom, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - 32)

            ScrollView {
                content(availableHeight)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: availableHeight, alignment: alignment)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
