import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class TipStore {
    private(set) var products: [String: Product] = [:]
    private(set) var isLoading = false
    private(set) var purchasingOption: TipOption?
    private(set) var loadingMessage: String?
    private(set) var purchaseMessage: String?
    var receipt: TipReceipt?

    @ObservationIgnored private var handledTransactionIDs: Set<UInt64> = []

    var isPurchasing: Bool { purchasingOption != nil }

    func product(for option: TipOption) -> Product? {
        products[option.productID]
    }

    func displayPrice(for option: TipOption, quantity: Int = 1) -> String? {
        guard option.supports(quantity: quantity), let product = product(for: option) else { return nil }
        return quantity == 1 ? product.displayPrice : (product.price * Decimal(quantity)).formatted(product.priceFormatStyle)
    }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        loadingMessage = nil
        defer { isLoading = false }

        do {
            let availableProducts = try await Product.products(for: TipOption.allCases.map(\.productID))
            try Task.checkCancellation()
            products = Dictionary(uniqueKeysWithValues: availableProducts.filter {
                $0.type == .consumable && $0.price > 0
            }.map { ($0.id, $0) })
            if products.count < TipOption.allCases.count {
                loadingMessage = "Some tips aren’t available right now. Please try again later."
            }
        } catch is CancellationError {
            // A dismissed view can retry the request when it opens again.
        } catch {
            loadingMessage = "Couldn’t load tips from the App Store. Check your connection and try again."
        }
    }

    func purchase(
        _ option: TipOption,
        quantity: Int = 1,
        using action: (Product, Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult
    ) async {
        guard !isPurchasing else { return }
        guard option.supports(quantity: quantity), let product = product(for: option) else {
            purchaseMessage = "This tip isn’t available. Please reload the tip options and try again."
            return
        }

        purchasingOption = option
        purchaseMessage = nil
        defer { purchasingOption = nil }

        do {
            switch try await action(product, [.quantity(quantity)]) {
            case .success(let verification):
                await process(verification)
            case .pending:
                purchaseMessage = "Your tip is awaiting approval. We’ll say thank you once the App Store confirms it."
            case .userCancelled:
                break
            @unknown default:
                purchaseMessage = "The App Store hasn’t confirmed your tip yet. Please try again later."
            }
        } catch is CancellationError {
            // Cancellation never counts as a successful tip.
        } catch StoreKitError.userCancelled {
            // Closing Apple's confirmation sheet needs no error message.
        } catch {
            purchaseMessage = "Your tip couldn’t be completed. Please try again."
        }
    }

    // Owned by the app's root task, so approvals and interrupted purchases are
    // processed even while Settings is closed. Both sequences share deduplication.
    func observeTransactions() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await verification in Transaction.updates {
                    guard !Task.isCancelled else { return }
                    await self.process(verification)
                }
            }
            group.addTask {
                for await verification in Transaction.unfinished {
                    guard !Task.isCancelled else { return }
                    await self.process(verification)
                }
            }
        }
    }

    func process(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else {
            if TipOption.allCases.contains(where: { $0.productID == verification.unsafePayloadValue.productID }) {
                purchaseMessage = "The App Store couldn’t verify this tip. Please try again later."
            }
            return
        }
        guard let option = TipOption.allCases.first(where: { $0.productID == transaction.productID }),
              transaction.productType == .consumable else { return }
        guard transaction.revocationDate == nil else {
            await transaction.finish()
            return
        }
        guard handledTransactionIDs.insert(transaction.id).inserted else { return }

        let displayAmount: String?
        if let price = transaction.price, let currency = transaction.currency {
            // Transaction.price already includes purchasedQuantity.
            displayAmount = price.formatted(.currency(code: currency.identifier))
        } else {
            displayAmount = displayPrice(for: option, quantity: transaction.purchasedQuantity)
        }
        purchaseMessage = nil
        receipt = TipReceipt(id: transaction.id, option: option, displayAmount: displayAmount)
        await transaction.finish()
    }
}
