import SwiftUI

struct IntroductionEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    let isActive: Bool
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(hasEntered ? 1 : 0)
            .offset(y: hasEntered || reduceMotion ? 0 : 18)
            .scaleEffect(hasEntered || reduceMotion ? 1 : 0.98)
            .allowsHitTesting(hasEntered)
            .accessibilityHidden(!hasEntered)
            .task(id: isActive) {
                await updateVisibility(isActive)
            }
    }

    private func updateVisibility(_ active: Bool) async {
        if active {
            guard !hasEntered else { return }
            if !reduceMotion && delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.85, bounce: 0.1)) {
                hasEntered = true
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasEntered = false
            }
        }
    }
}
