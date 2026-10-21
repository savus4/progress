import SwiftUI

struct PhotoLocalStorageConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let estimate: PhotoStorageEstimate
    let onConfirm: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Save all originals on this device and stop syncing changes to iCloud.")
                    LabeledContent("Photos", value: "\(estimate.photoCount)")
                    LabeledContent("Originals", value: bytes(estimate.originalBytes))
                    if estimate.requiredDeviceBytes > 0 {
                        LabeledContent("Free Space Needed", value: bytes(estimate.requiredDeviceBytes))
                        LabeledContent("Available on Device", value: bytes(estimate.freeDeviceBytes))
                    }
                }

                Section {
                    Button {
                        onConfirm(false)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Keep iCloud Copies")
                            Text("Leave existing photos in iCloud.")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("keepICloudCopiesButton")

                    Button(role: .destructive) {
                        onConfirm(true)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Remove iCloud Copies")
                            Text("Remove this app’s cloud library from all synced devices.")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("removeICloudCopiesButton")
                } header: {
                    Text("Existing iCloud Copies")
                } footer: {
                    Text("iCloud copies are removed only after every original is verified on this device. Turn off sync on other devices to prevent them uploading photos again.")
                }
            }
            .navigationTitle("Use Local Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
}
