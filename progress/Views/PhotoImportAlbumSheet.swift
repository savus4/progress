import SwiftUI

struct PhotoImportAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    let albums: [PhotoImportAlbum]
    let timelineID: UUID

    var body: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    PhotoImportCoordinator.shared.importAlbum(album, timelineID: timelineID)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.title)
                                .foregroundStyle(.primary)
                            Text("\(album.assetCount) photo\(album.assetCount == 1 ? "" : "s")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .overlay {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums to Import",
                        systemImage: "rectangle.stack",
                        description: Text("Albums with photos will appear here.")
                    )
                }
            }
            .navigationTitle("Import Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
