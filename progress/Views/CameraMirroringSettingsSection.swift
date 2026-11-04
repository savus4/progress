import SwiftUI

struct CameraMirroringSettingsSection: View {
    @AppStorage(CameraPreferenceKey.hirsModeEnabled) private var isHirsModeEnabled = false
    @AppStorage(CameraPreferenceKey.hirsModeProEnabled) private var isHirsModeProEnabled = false

    var body: some View {
        Section {
            Toggle("Hirs Mode", isOn: $isHirsModeEnabled)
                .accessibilityIdentifier("hirsModeToggle")

            Toggle("Hirs Mode Pro", isOn: $isHirsModeProEnabled)
                .accessibilityIdentifier("hirsModeProToggle")
        } header: {
            Text("Camera")
        } footer: {
            Text("Hirs Mode mirrors previews. Pro mirrors all photos and exports.")
                .lineLimit(3)
                .accessibilityIdentifier("hirsModeDescription")
        }
        .onAppear {
            // Pro includes preview mirroring.
            if isHirsModeProEnabled { isHirsModeEnabled = true }
        }
        .onChange(of: isHirsModeProEnabled) { _, enabled in
            if enabled { isHirsModeEnabled = true }
        }
        .onChange(of: isHirsModeEnabled) { _, enabled in
            if !enabled { isHirsModeProEnabled = false }
        }
    }
}
