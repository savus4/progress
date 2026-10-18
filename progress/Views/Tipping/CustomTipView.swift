import StoreKit
import SwiftUI

struct CustomTipView: View {
    @Environment(TipStore.self) private var store
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    TipSnackIllustration(option: .custom)
                        .padding(20)
                        .background(.orange.opacity(0.08), in: Circle())
                        .padding(.top, 24)

                    VStack(spacing: 10) {
                        Text("A little goes a long way.")
                            .font(.largeTitle.bold())
                        Text("Choose a tip that feels right for you. Thank you for supporting this little app.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: 20) {
                        Text(store.displayPrice(for: .custom, quantity: quantity) ?? "Unavailable")
                            .font(.largeTitle.bold())
                            .fontDesign(.rounded)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("custom-tip-total")
                        Stepper("Amount", value: $quantity, in: TipOption.customQuantities)
                            .accessibilityIdentifier("custom-tip-stepper")
                            .accessibilityValue(store.displayPrice(for: .custom, quantity: quantity) ?? "Unavailable")
                        if let minimum = store.displayPrice(for: .custom),
                           let maximum = store.displayPrice(for: .custom, quantity: TipOption.customQuantities.upperBound) {
                            Text("From \(minimum) to \(maximum), in \(minimum) steps.\nA one-time tip. A big thank you.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))

                    if let message = store.purchaseMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            await store.purchase(.custom, quantity: quantity) { product, options in
                                try await purchase(product, options: options)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if store.isPurchasing { ProgressView().tint(.white) }
                            Text(store.isPurchasing ? "Confirming your tip…" : "Tip \(store.displayPrice(for: .custom, quantity: quantity) ?? "")")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color(red: 0.65, green: 0.25, blue: 0.06))
                    .disabled(store.isPurchasing || store.product(for: .custom) == nil)
                    .accessibilityIdentifier("custom-tip-purchase")
                }
                .padding(24)
            }
            .disabled(store.isPurchasing)
            .navigationTitle("Your Own Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .disabled(store.isPurchasing)
                }
            }
        }
    }
}
