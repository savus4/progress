import SwiftUI

struct CameraReferencePhotoToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool
    let isInteractionDisabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                Text("Reference")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(isOn && isAvailable ? 0.22 : 0.08))
            )
            .opacity(isAvailable ? 1 : 0.35)
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Previous Photo Reference")
        .accessibilityHint(isAvailable
            ? "Overlays the latest photo in this timeline, even when guides are hidden."
            : "Take a photo in this timeline to enable a reference.")
        .accessibilityIdentifier("experimentalCameraReferencePhotoToggle")
        .disabled(!isAvailable || isInteractionDisabled)
    }
}
