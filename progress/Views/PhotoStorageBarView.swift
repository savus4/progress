import SwiftUI

struct PhotoStorageBarView: View {
    let usage: LocalPhotoAssetStorageUsage
    let heartedBytes: Int64
    let recentBytes: Int64
    let recentLimitBytes: Int64?

    private var hearted: Int64 { min(Int64(usage.offlineOriginalBytes), max(0, heartedBytes)) }
    private var otherPhotos: Int64 { max(0, Int64(usage.offlineOriginalBytes) - hearted) }
    private var unusedLimit: Int64 { recentLimitBytes.map { max(0, $0 - recentBytes) } ?? 0 }
    private var scaleBytes: Double { max(1, Double(usage.totalBytes) + Double(unusedLimit)) }
    private var limitPosition: Double { (Double(usage.offlineOriginalBytes) + Double(unusedLimit)) / scaleBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Photos on Device").font(.headline)
                Spacer()
                Text(formatted(Int64(usage.totalBytes)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        segment(bytes: hearted, color: .pink, width: geometry.size.width)
                        segment(bytes: otherPhotos, color: .teal, width: geometry.size.width)
                        segment(bytes: unusedLimit, color: .secondary.opacity(0.12), width: geometry.size.width)
                        segment(bytes: Int64(usage.pendingUploadBytes), color: .orange, width: geometry.size.width)
                        segment(bytes: Int64(usage.cachedFullResolutionBytes), color: .gray.opacity(0.5), width: geometry.size.width)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .frame(height: 18)

                    if recentLimitBytes != nil {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary.opacity(0.7))
                            .frame(width: 2, height: 26)
                            .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * limitPosition - 1)))
                    }
                }
                .frame(height: 26)
            }
            .frame(height: 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo storage usage")
            .accessibilityValue("Hearted photos \(formatted(hearted)), other photos \(formatted(otherPhotos)), pending uploads \(formatted(Int64(usage.pendingUploadBytes))), cache \(formatted(Int64(usage.cachedFullResolutionBytes)))")

            if let recentLimitBytes {
                HStack {
                    Label("Recent Photo Limit", systemImage: "line.3.horizontal.decrease")
                    Spacer()
                    Text(formatted(recentLimitBytes)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    legend("Hearted", bytes: hearted, color: .pink)
                    legend("Other Photos", bytes: otherPhotos, color: .teal)
                }
                GridRow {
                    legend("Pending Uploads", bytes: Int64(usage.pendingUploadBytes), color: .orange)
                    legend("Cache", bytes: Int64(usage.cachedFullResolutionBytes), color: .gray)
                }
            }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.25), value: usage)
        .accessibilityIdentifier("photoStorageUsageBar")
    }

    private func segment(bytes: Int64, color: Color, width: CGFloat) -> some View {
        color.frame(width: width * Double(max(0, bytes)) / scaleBytes)
    }

    private func legend(_ title: String, bytes: Int64, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption)
                Text(formatted(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
}
