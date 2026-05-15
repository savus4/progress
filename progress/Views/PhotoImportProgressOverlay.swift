import SwiftUI

struct PhotoImportProgressOverlay: View {
    @ObservedObject var importer: PhotoImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if importer.isImporting {
                importProgressContent
            } else if let completionMessage = importer.completionMessage {
                completionContent(message: completionMessage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.96).combined(with: .opacity)
        ))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoImportProgressOverlay")
    }

    private var importProgressContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text("Importing Photos")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(importer.processedCount)/\(max(importer.totalCount, 1))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(
                value: Double(importer.processedCount),
                total: Double(max(importer.totalCount, 1))
            )
            .tint(.primary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(importer.progressDescription)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let remainingTimeText = importer.remainingTimeText {
                        Spacer(minLength: 8)

                        Text(remainingTimeText)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Stay in the app until import finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func completionContent(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text("Import Complete")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}
