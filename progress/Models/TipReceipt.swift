import Foundation

struct TipReceipt: Identifiable {
    let id: UInt64
    let option: TipOption
    let displayAmount: String?
}
