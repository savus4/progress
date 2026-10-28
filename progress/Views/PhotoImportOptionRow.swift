import SwiftUI

struct PhotoImportOptionRow: View {
    let method: PhotoImportMethod
    let hasFullAccess: Bool
    let isPreparing: Bool

    private var tint: Color {
        switch method {
        case .photos: .blue
        case .privatePhotos: .teal
        case .album: .indigo
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: method.systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.1), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(method.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Label(
                    method.requiresFullAccess ? "Includes Live Photos" : "Still photos only",
                    systemImage: method.requiresFullAccess ? "livephoto" : "photo"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(accessDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPreparing {
                ProgressView()
                    .accessibilityLabel("Preparing import")
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    private var accessDescription: String {
        guard method.requiresFullAccess else { return "No library access needed" }
        return hasFullAccess ? "Full Photos access enabled" : "Requires Full Photos access"
    }
}

#Preview("Import options") {
    Form {
        ForEach(PhotoImportMethod.allCases) { method in
            Section {
                PhotoImportOptionRow(method: method, hasFullAccess: false, isPreparing: false)
            }
        }
    }
}

#Preview("Large text · Access enabled") {
    Form {
        PhotoImportOptionRow(method: .photos, hasFullAccess: true, isPreparing: false)
        PhotoImportOptionRow(method: .album, hasFullAccess: true, isPreparing: true)
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
