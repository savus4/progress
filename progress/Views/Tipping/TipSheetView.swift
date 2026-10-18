import SwiftUI

struct TipSheetView: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Group {
            if let receipt = store.receipt {
                TipThankYouView(receipt: receipt)
            } else {
                CustomTipView()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(store.isPurchasing)
    }
}
