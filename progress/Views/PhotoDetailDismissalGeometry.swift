import CoreGraphics

enum PhotoDetailDismissalGeometry {
    static func draggedFrame(
        imageSize: CGSize,
        viewportSize: CGSize,
        translation: CGSize,
        reduceMotion: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let fit = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        let scale = reduceMotion ? 1 : max(0.55, 1 - max(translation.height, 0) / (viewportSize.height * 0.9))
        let size = CGSize(width: imageSize.width * fit * scale, height: imageSize.height * fit * scale)
        return CGRect(
            x: (viewportSize.width - size.width) / 2 + (reduceMotion ? 0 : translation.width),
            y: (viewportSize.height - size.height) / 2 + (reduceMotion ? 0 : translation.height),
            width: size.width,
            height: size.height
        )
    }
}
