import StoreKit
import SwiftUI

struct TipJarSection: View {
    @Environment(TipStore.self) private var store
    @Environment(\.purchase) private var purchase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsTipSheet = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("A LITTLE SUPPORT", systemImage: "heart")
                        .font(.caption2.weight(.bold))
                        .tracking(1.7)
                        .foregroundStyle(.secondary)
                    Text("Enjoying the progress?")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Treat me to a little snack and help keep Work in Progress growing. Every tip means a lot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.isLoading && store.products.isEmpty {
                    ProgressView("Loading tips…")
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 12))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    layout {
                        tipButton(.chips)
                        tipButton(.fries)
                    }

                    Button {
                        showsTipSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.circle")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Choose your own amount")
                                    .font(.subheadline.weight(.semibold))
                                if let minimum = store.displayPrice(for: .custom) {
                                    Text("From \(minimum)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.product(for: .custom) == nil)
                    .accessibilityIdentifier("tip-custom")
                }

                if let message = store.loadingMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Reload Tips", systemImage: "arrow.clockwise") {
                            Task { await store.loadProducts() }
                        }
                        .font(.footnote.weight(.semibold))
                        .disabled(store.isLoading)
                    }
                }
                if let message = store.purchaseMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tip-purchase-message")
                }

                Text("Always optional. Just a little kindness. ♡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(LinearGradient(colors: [.orange.opacity(0.12), .yellow.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .disabled(store.isPurchasing)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .task {
            await store.loadProducts()
            if store.receipt != nil { showsTipSheet = true }
        }
        .onChange(of: store.receipt?.id) { _, id in
            if id != nil { showsTipSheet = true }
        }
        .sheet(isPresented: $showsTipSheet, onDismiss: { store.receipt = nil }) {
            TipSheetView()
                .environment(store)
        }
    }

    private func tipButton(_ option: TipOption) -> some View {
        TipOptionButton(
            option: option,
            price: store.displayPrice(for: option),
            isPurchasing: store.purchasingOption == option
        ) {
            Task {
                await store.purchase(option) { product, options in
                    try await purchase(product, options: options)
                }
            }
        }
    }
}
