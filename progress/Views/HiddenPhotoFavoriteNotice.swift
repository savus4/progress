import SwiftUI

struct HiddenPhotoFavoriteNotice: View {
    static let message = "This photo is hidden from videos and can’t be favorited. Choose “Unhide from Video” in the ellipsis menu first."

    var body: some View {
        Label(Self.message, systemImage: "eye.slash.fill")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hiddenPhotoFavoriteNotice")
            .allowsHitTesting(false)
    }
}
