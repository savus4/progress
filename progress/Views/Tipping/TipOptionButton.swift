import SwiftUI

struct TipOptionButton: View {
    let option: TipOption
    let price: String?
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                TipSnackIllustration(option: option)
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                if isPurchasing {
                    ProgressView("Confirming…")
                        .font(.caption)
                } else {
                    Text(price ?? "Unavailable")
                        .font(.headline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.orange.opacity(0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .disabled(price == nil)
        .accessibilityLabel("Tip \(price ?? "unavailable"), \(option.title)")
        .accessibilityHint("Opens the App Store purchase confirmation")
        .accessibilityIdentifier("tip-\(option.rawValue)")
    }
}
