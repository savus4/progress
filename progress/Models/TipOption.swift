import Foundation

enum TipOption: String, CaseIterable, Identifiable {
    case chips
    case fries
    case custom

    var id: String { rawValue }

    var productID: String { "me.riepl.progress.tip.\(rawValue)" }

    var title: String {
        switch self {
        case .chips: "A bag of chips"
        case .fries: "A side of fries"
        case .custom: "Your own amount"
        }
    }

    // StoreKit supports at most ten units of a consumable in one purchase.
    static let customQuantities = 1...10

    func supports(quantity: Int) -> Bool {
        self == .custom ? Self.customQuantities.contains(quantity) : quantity == 1
    }
}
