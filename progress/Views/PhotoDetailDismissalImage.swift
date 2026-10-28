import SwiftUI

struct PhotoDetailDismissalImage: View {
    let image: UIImage
    let frame: CGRect
    let cornerRadius: CGFloat

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: frame.width, height: frame.height)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .position(x: frame.midX, y: frame.midY)
            .accessibilityIdentifier("photoDetailImage")
    }
}
