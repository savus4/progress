import SwiftUI

struct IntroductionPreviewView: View {
    let availableHeight: CGFloat
    let isActive: Bool
    let hasAppeared: Bool

    var body: some View {
        IntroductionPreviewLayout(availableHeight: availableHeight) {
            IntroductionVideoView(isActive: isActive)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)

            VStack(spacing: 12) {
                Text("Work in Progress")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .modifier(IntroductionEntrance(isActive: hasAppeared, delay: 0.35))

                Text("One photo a day.\nIt does not matter, when you start.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .modifier(IntroductionEntrance(isActive: hasAppeared, delay: 0.5))
            }
        }
    }
}
