import SwiftUI

struct TipThankYouView: View {
    let receipt: TipReceipt
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 28)
                illustration
                    .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.85)
                    .opacity(hasAppeared ? 1 : 0)

                VStack(spacing: 14) {
                    Text("Small snack.\nHuge thank you.")
                        .font(.largeTitle.bold())
                        .fontDesign(.rounded)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("tip-thank-you-title")
                    Text("Your kindness helps me keep building Work in Progress. I’m so happy it’s part of your story.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label(receipt.displayAmount.map { "\($0) tip received" } ?? "Tip received", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.background.opacity(0.8), in: Capsule())
                    .accessibilityIdentifier("tip-received")

                VStack(spacing: 6) {
                    Text("With gratitude,")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Simon ♡")
                        .font(.title2.weight(.semibold))
                        .fontDesign(.rounded)
                }
                .padding(.vertical, 8)

                Button("Back to Settings") { dismiss() }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color(red: 0.65, green: 0.25, blue: 0.06))
                    .accessibilityIdentifier("tip-thank-you-done")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [.orange.opacity(0.13), .yellow.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.65, bounce: 0.25)) {
                hasAppeared = true
            }
        }
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(.orange.opacity(0.06))
                .frame(width: 220, height: 220)
            Circle()
                .strokeBorder(.orange.opacity(0.12), lineWidth: 1)
                .frame(width: 178, height: 178)
            TipSnackIllustration(option: receipt.option)
                .scaleEffect(1.65)
            Image(systemName: "heart.fill")
                .foregroundStyle(.pink.gradient)
                .font(.title2)
                .rotationEffect(.degrees(15))
                .offset(x: 76, y: -60)
            Image(systemName: "sparkle")
                .foregroundStyle(.orange)
                .font(.title2)
                .offset(x: -76, y: -40)
            Image(systemName: "sparkle")
                .foregroundStyle(.orange.opacity(0.7))
                .font(.subheadline)
                .offset(x: 66, y: 67)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }
}

#Preview {
    TipThankYouView(receipt: TipReceipt(id: 1, option: .fries, displayAmount: "$5.00"))
}
