import SwiftUI

struct IntroductionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPage = IntroductionPage.preview
    @State private var hasAppeared = false
    @State private var isFinishing = false
    @State private var hasExited = false

    let onFinish: () -> Void

    private var showsFeatures: Bool { selectedPage == .features }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPage) {
                Tab(value: IntroductionPage.preview) {
                    IntroductionPageContainer { availableHeight in
                        IntroductionPreviewView(
                            availableHeight: availableHeight,
                            isActive: selectedPage == .preview && hasAppeared,
                            hasAppeared: hasAppeared
                        )
                    }
                    .accessibilityIdentifier("introductionPreviewPage")
                }

                Tab(value: IntroductionPage.features) {
                    IntroductionPageContainer(alignment: .center) { _ in
                        IntroductionFeaturesView(isActive: showsFeatures && hasAppeared)
                    }
                    .accessibilityIdentifier("introductionFeaturesPage")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(showsFeatures ? Color.secondary.opacity(0.25) : Color.accentColor)
                        .frame(width: 24, height: 5)
                    Capsule()
                        .fill(showsFeatures ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 24, height: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(showsFeatures ? "Introduction, page 2 of 2" : "Introduction, page 1 of 2")
                .modifier(IntroductionEntrance(isActive: hasAppeared, delay: 0.65))

                Button(action: advance) {
                    Text(showsFeatures ? "Get Started" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasAppeared || isFinishing)
                .accessibilityIdentifier("introductionContinueButton")
                .modifier(IntroductionEntrance(isActive: hasAppeared, delay: 0.85))
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                Rectangle()
                    .fill(.background)
                IntroductionParticlesView()
            }
            .ignoresSafeArea()
        }
        .opacity(hasExited ? 0 : 1)
        .scaleEffect(hasExited && !reduceMotion ? 0.97 : 1)
        .allowsHitTesting(hasAppeared && !isFinishing)
        .accessibilityHidden(!hasAppeared)
        .task {
            await revealContent()
        }
    }

    private func advance() {
        guard !isFinishing else { return }
        if showsFeatures {
            isFinishing = true
            withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.35)) {
                hasExited = true
            } completion: {
                onFinish()
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedPage = .features
            }
        }
    }

    private func revealContent() async {
        guard !hasAppeared else { return }
        do {
            try await Task.sleep(for: .milliseconds(700))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        hasAppeared = true
    }
}

#Preview {
    IntroductionView(onFinish: {})
}
