import SwiftUI

struct PhotoStorageLimitView: View {
    @Binding var limitBytes: Double
    @State private var availableBytes: Int64?
    @State private var limitInput = ""
    @State private var isLoading = true
    @FocusState private var isEditing: Bool

    private var steps: PhotoStorageLimitSteps { PhotoStorageLimitSteps(availableBytes: availableBytes ?? 0) }
    private var canEdit: Bool { (availableBytes ?? 0) >= PhotoOfflineSettings.minimumLimitBytes }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Storage Limit")
                    Spacer()
                    TextField("MB", text: $limitInput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($isEditing)
                        .frame(maxWidth: 140)
                        .accessibilityIdentifier("recentPhotoStorageLimitField")
                    Text("MB").foregroundStyle(.secondary)
                }
                Slider(value: sliderBinding, in: 0...Double(max(1, steps.maximumIndex)), step: 1)
                    .disabled(steps.maximumIndex == 0)
                    .accessibilityLabel("Storage Limit")
                    .accessibilityValue(formattedBytes(limitBytes))
                    .accessibilityIdentifier("recentPhotoStorageLimitSlider")
                HStack {
                    Text("100 MB")
                    Spacer()
                    Text(formattedBytes(Double(steps.maximumBytes)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(!canEdit)

            Section {
                if isLoading {
                    ProgressView("Checking Device Storage")
                } else {
                    LabeledContent("Free Device Storage", value: availableBytes.map { formattedBytes(Double($0)) } ?? "Unavailable")
                }
            }
        }
        .navigationTitle("Storage Limit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { saveInput(); isEditing = false }
            }
        }
        .task {
            updateInput()
            availableBytes = await PhotoOfflineStorageCapacity.availableBytes()
            isLoading = false
        }
        .onChange(of: isEditing) { _, editing in if !editing { saveInput() } }
        .onDisappear { if isEditing { saveInput() } }
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { Double(steps.index(for: limitBytes)) }, set: {
            limitBytes = Double(steps.bytes(at: Int($0.rounded())))
            updateInput()
        })
    }

    private func saveInput() {
        if canEdit, let megabytes = Double(limitInput.replacingOccurrences(of: ",", with: ".")), megabytes.isFinite {
            limitBytes = Double(steps.snappedBytes(megabytes * 1_000_000))
        }
        updateInput()
    }

    private func updateInput() { limitInput = (limitBytes / 1_000_000).formatted(.number.grouping(.never).precision(.fractionLength(0...1))) }
    private func formattedBytes(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal) }
}
