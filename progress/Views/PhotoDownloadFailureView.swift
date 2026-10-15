import SwiftUI

struct PhotoDownloadFailureView: View {
    let failure: PhotoDownloadFailure
    let isLiveMotion: Bool
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Label(failure.title, systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(failure.message(isLiveMotion: isLiveMotion))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if canRetry {
                Button("Retry Download", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retryPhotoDownloadButton")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("photoDownloadFailure")
    }
}
