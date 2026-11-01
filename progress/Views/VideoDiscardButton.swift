import SwiftUI
import UIKit

struct VideoDiscardButton: UIViewControllerRepresentable {
    let onDiscard: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onDiscard = onDiscard
        controller.button.isEnabled = isEnabled
    }

    final class Controller: UIViewController {
        let button = UIButton(type: .system)
        var onDiscard: () -> Void = {}

        override func loadView() {
            var configuration = UIButton.Configuration.glass()
            configuration.image = UIImage(systemName: "trash.fill")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
            configuration.baseForegroundColor = .systemRed
            configuration.cornerStyle = .capsule
            configuration.contentInsets = .zero
            button.configuration = configuration
            button.accessibilityLabel = "Discard Video"
            button.addTarget(self, action: #selector(showConfirmation), for: .touchUpInside)
            view = button
        }

        @objc private func showConfirmation() {
            guard button.isEnabled, view.window != nil, presentedViewController == nil else { return }

            let confirmation = UIAlertController(
                title: "Discard video?",
                message: "This action cannot be undone.",
                preferredStyle: .actionSheet
            )
            confirmation.addAction(UIAlertAction(title: "Discard Video", style: .destructive) { [weak self] _ in
                self?.onDiscard()
            })
            confirmation.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirmation.popoverPresentationController?.sourceItem = button
            present(confirmation, animated: true)
        }
    }
}
