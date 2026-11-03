import SwiftUI

struct CameraCaptureStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let phase: CameraCapturePhase

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: phase.symbolName)
                .font(.title3)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.title)
                    .font(.subheadline.weight(.semibold))
                Text(phase.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            ProgressView()
                .tint(.white)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cameraCaptureStatus")
    }
}
