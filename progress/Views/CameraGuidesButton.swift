import SwiftUI

struct CameraGuidesButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let guidesVisible: Bool
    let showsIntroduction: Bool
    let action: () -> Void

    private var pulses: Bool { showsIntroduction && !reduceMotion }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: guidesVisible ? "eye" : "eye.slash")
                    .font(.title3)
                    .animation(nil, value: guidesVisible)
                Text("Guides")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(.white.opacity(pulses ? 0.24 : 0.08), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(showsIntroduction ? 0.7 : 0), lineWidth: 1)
            }
            .scaleEffect(pulses ? 1.08 : 1)
            .animation(pulses ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                       : .easeOut(duration: 0.18), value: pulses)
        }
        .accessibilityLabel("Edit Alignment Guides")
        .accessibilityIdentifier("experimentalCameraGuidesButton")
        .accessibilityHint("Adjust the guides to align your eyes and mouth.")
    }
}
