import SwiftUI

struct IntroductionVideoPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var isActive = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.65), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 24) {
                Spacer(minLength: 0)

                Image(systemName: "photo.stack")
                    .font(.largeTitle.scaled(by: 1.6))
                    .symbolEffect(.breathe, isActive: isActive && !reduceMotion && scenePhase == .active)

                VStack(spacing: 8) {
                    Text("Your story,\nin motion.")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("App preview coming soon")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                Label("Video preview", systemImage: "play.rectangle")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App video preview coming soon")
    }
}

#Preview {
    IntroductionVideoPlaceholder()
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(width: 240)
}
