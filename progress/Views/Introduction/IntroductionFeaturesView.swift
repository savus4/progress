import SwiftUI

struct IntroductionFeaturesView: View {
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Made for the\nlong run.")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("It feels small today. Then you blink, and you have a decade to look back on.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(IntroductionEntrance(isActive: isActive))

            VStack(alignment: .leading, spacing: 28) {
                IntroductionFeatureView(
                    title: "Years of photos. Still fast.",
                    detail: "Built to keep browsing smooth, even with thousands of pictures.",
                    symbol: "square.stack.3d.up",
                    tint: .blue
                )
                .modifier(IntroductionEntrance(isActive: isActive, delay: 0.08))
                IntroductionFeatureView(
                    title: "Life in every Live Photo",
                    detail: "Keep the movement and sound of some special moments.",
                    symbol: "livephoto",
                    tint: .orange
                )
                .modifier(IntroductionEntrance(isActive: isActive, delay: 0.16))
                IntroductionFeatureView(
                    title: "Your story, in motion",
                    detail: "Turn your photos into a heartfelt video, with plenty of ways to make it your own.",
                    symbol: "film.stack",
                    tint: .pink
                )
                .modifier(IntroductionEntrance(isActive: isActive, delay: 0.24))
                IntroductionFeatureView(
                    title: "Remember where",
                    detail: "Save locations with your photos if you want, and revisit them on the map.",
                    symbol: "map",
                    tint: .green
                )
                .modifier(IntroductionEntrance(isActive: isActive, delay: 0.32))
                IntroductionFeatureView(
                    title: "Your memories stay yours",
                    detail: "Your library syncs through your iCloud account or just stays on your device. Choose in settings. No matter what: we don't see your photos.",
                    symbol: "lock.shield",
                    tint: .purple
                )
                .modifier(IntroductionEntrance(isActive: isActive, delay: 0.4))
            }
        }
        .padding(.vertical, 16)
    }
}

#Preview {
    ScrollView {
        IntroductionFeaturesView(isActive: true)
            .padding(24)
    }
}
