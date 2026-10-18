import Foundation
import StoreKit
import StoreKitTest
import Testing
import UIKit
@testable import progress

@MainActor
struct TipStoreTests {
    @Test("Verified repeat tips, custom totals, and incomplete purchases", .timeLimit(.minutes(2)))
    func purchaseLifecycle() async throws {
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.clearTransactions() }

        let store = TipStore()
        await store.loadProducts()
        #expect(store.loadingMessage == nil)
        try #require(store.products.count == 3)
        #expect(store.product(for: .chips)?.price == 3)
        #expect(store.product(for: .fries)?.price == 5)
        #expect(store.product(for: .custom)?.price == 10)

        let first = try await session.buyProduct(identifier: TipOption.chips.productID)
        await store.purchase(.chips) { _, _ in .success(.verified(first)) }
        #expect(store.receipt?.id == first.id)
        #expect(store.receipt?.option == .chips)
        #expect(!store.isPurchasing)

        // A purchase result and Transaction.updates can deliver the same ID.
        store.receipt = nil
        await store.process(.verified(first))
        #expect(store.receipt == nil)

        let second = try await session.buyProduct(identifier: TipOption.chips.productID)
        await store.purchase(.chips) { _, _ in .success(.verified(second)) }
        #expect(second.id != first.id)
        #expect(store.receipt?.id == second.id)

        store.receipt = nil
        await store.purchase(.fries) { _, _ in .userCancelled }
        #expect(store.receipt == nil)
        #expect(store.purchaseMessage == nil)

        await store.purchase(.fries) { _, _ in .pending }
        #expect(store.receipt == nil)
        #expect(store.purchaseMessage?.contains("awaiting approval") == true)

        await store.purchase(.fries) { _, _ in throw StoreKitError.networkError(URLError(.notConnectedToInternet)) }
        #expect(store.receipt == nil)
        #expect(store.purchaseMessage?.contains("couldn’t be completed") == true)
        #expect(!store.isPurchasing)

        // Delayed approval follows the transaction listener's processing path.
        let approved = try await session.buyProduct(identifier: TipOption.fries.productID)
        await store.process(.verified(approved))
        #expect(store.receipt?.option == .fries)
        #expect(store.purchaseMessage == nil)

        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        await store.purchase(.custom, quantity: 4) { product, options in
            #expect(product.id == TipOption.custom.productID)
            #expect(options == [.quantity(4)])
            return try await product.purchase(confirmIn: scene, options: options)
        }
        #expect(store.receipt?.displayAmount == Decimal(40).formatted(.currency(code: "USD")))
        #expect(store.displayPrice(for: .custom, quantity: 10) == Decimal(100).formatted(try #require(store.product(for: .custom)).priceFormatStyle))

        store.receipt = nil
        await store.process(.unverified(approved, .invalidSignature))
        #expect(store.receipt == nil)
        #expect(store.purchaseMessage?.contains("couldn’t verify") == true)

        for quantity in [0, 11, -1] {
            await store.purchase(.custom, quantity: quantity) { _, _ in
                Issue.record("Invalid quantities must never reach StoreKit")
                return .userCancelled
            }
            #expect(store.receipt == nil)
        }
    }
}
