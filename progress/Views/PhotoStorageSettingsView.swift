import SwiftUI

struct PhotoStorageSettingsView: View {
    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared
    @State private var storage = PhotoStorageCoordinator.shared
    @State private var iCloudEnabled = !PhotoStorageCoordinator.shared.isLocalOnly
    @State private var estimate: PhotoStorageEstimate?
    @State private var isChecking = false
    @State private var showsLocalChoice = false
    @State private var showsUploadConsent = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: $iCloudEnabled)
                    .disabled(storage.usesSimulatorExampleLibrary || isChecking || storage.isWorking || storage.mode.isMigrating)
                    .accessibilityIdentifier("iCloudSyncToggle")
                Text(storageExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photoStorageExplanation")
            } header: {
                Text("Photo Storage")
            } footer: {
                if storage.usesSimulatorExampleLibrary {
                    Text("The example library is separate from your normal photo library. To test iCloud storage, relaunch with SIMULATOR_EXAMPLE_PHOTOS=0 in the Run environment.")
                } else {
                    Text("Applies to this device. Photos in Apple’s Photos app are unaffected. Manage existing device backups in iOS Settings.")
                }
            }

            if isChecking { Section { ProgressView("Checking originals and storage…") } }

            if storage.mode.isMigrating || storage.statusMessage != nil {
                Section("Storage Switch") {
                    if storage.isWorking {
                        ProgressView(value: Double(storage.completedAssets), total: Double(max(1, storage.totalAssets)))
                        Text("\(storage.completedAssets) of \(storage.totalAssets) originals verified")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = storage.statusMessage { Text(message).font(.footnote) }
                    if let message = storage.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
                    if storage.mode.isMigrating {
                        Text("Keep the app open to finish sooner. The switch resumes if interrupted. Adding and deleting photos is paused until it finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Retry Storage Switch") { storage.resume() }
                            .disabled(storage.isWorking)
                        if storage.mode == .downloading {
                            Button("Cancel Switch and Keep iCloud") {
                                Task {
                                    do { try await storage.cancelLocalSwitch() }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        }
                        if storage.mode == .preparingUpload && !storage.isWorking {
                            Button("Cancel Upload Preparation and Stay Local") {
                                Task {
                                    do { try await storage.cancelUploadPreparation() }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }

            Section("Advanced") {
                NavigationLink(value: PhotoSettingsDestination.storageManagement) {
                    Label("Storage Management", systemImage: "internaldrive")
                }
                .accessibilityIdentifier("storageManagementSettingsLink")
            }
        }
        .navigationTitle("Photo Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: iCloudEnabled) { _, value in
            guard value != !storage.isLocalOnly else { return }
            // The control reflects the committed preference until confirmation.
            iCloudEnabled = !storage.isLocalOnly
            checkStorage(forLocalStorage: !value)
        }
        .onChange(of: storage.mode) { _, _ in iCloudEnabled = !storage.isLocalOnly }
        .sheet(isPresented: $showsLocalChoice) {
            if let estimate {
                PhotoLocalStorageConfirmationView(estimate: estimate) { removeCloudCopies in
                    showsLocalChoice = false
                    beginLocal(removeCloudCopies: removeCloudCopies)
                }
            }
        }
        .sheet(isPresented: $showsUploadConsent) {
            NavigationStack {
                Form {
                    Section("iCloud Sync") {
                        Text("Merge this device’s photos with your private iCloud library. Photos, Live Photos, thumbnails, edits, and deletions sync across devices. Photos deleted locally return if their iCloud copies were kept.")
                        LabeledContent("Photos", value: "\(estimate?.photoCount ?? 0)")
                        LabeledContent("Originals to Upload", value: bytes(estimate?.originalBytes ?? 0))
                    }
                    Section("iCloud Storage") {
                        Text("Allow at least \(bytes(estimate?.originalBytes ?? 0)), plus space for thumbnails and photo details. Check available space in iOS Settings → your name → iCloud.")
                    }
                    Section {
                        Button("Enable iCloud Sync") { beginUpload() }
                            .disabled(isChecking)
                            .accessibilityIdentifier("confirmPrivateICloudUploadButton")
                    }
                }
                .navigationTitle("Enable iCloud")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsUploadConsent = false } } }
            }
        }
        .alert("Photo Storage Needs Attention", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var storageExplanation: String {
        if storage.usesSimulatorExampleLibrary {
            return "Simulator example photos stay on this simulator. iCloud sync is disabled for this example library."
        }
        return switch storage.mode {
        case .downloading:
            "Sync is paused while originals download and are verified. iCloud copies are kept until verification finishes."
        case .local, .deletingCloudCopies, .preparingUpload:
            "Photos stay on this device only, with sync and device backups off. Export a backup to avoid losing photos if you delete the app or lose this device."
        case .iCloud:
            syncMonitor.isICloudUnavailable ? syncMonitor.statusDetail : "Photos, Live Photos, thumbnails, and photo details sync privately to your iCloud account."
        }
    }

    private func checkStorage(forLocalStorage: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let result = try await storage.estimate(forLocalStorage: forLocalStorage)
                guard !forLocalStorage || result.fitsOnDevice else {
                    throw PhotoStorageMigrationError.attention("The switch needs up to \(bytes(result.peakAdditionalDeviceBytes)) for working copies, plus \(bytes(result.safetyMarginBytes)) kept free as a safety margin: \(bytes(result.requiredDeviceBytes)) total free space. Only \(bytes(result.freeDeviceBytes)) is available. Free space and try again.")
                }
                estimate = result
                if forLocalStorage { showsLocalChoice = true }
                else { showsUploadConsent = true }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func beginLocal(removeCloudCopies: Bool) {
        isChecking = true
        Task {
            defer { isChecking = false }
            do { try await storage.beginLocalStorage(removeCloudCopies: removeCloudCopies) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func beginUpload() {
        showsUploadConsent = false
        isChecking = true
        Task {
            defer { isChecking = false }
            do { try await storage.beginICloudStorage() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }
}
