/// A shutter-time snapshot, retained through review and save retries.
nonisolated struct CameraMirroring: Sendable {
    let savesMirrored: Bool
    let mirrorsPreviewOnly: Bool

    init(hirsModeEnabled: Bool, hirsModeProEnabled: Bool) {
        savesMirrored = hirsModeProEnabled
        mirrorsPreviewOnly = hirsModeEnabled && !hirsModeProEnabled
    }

    var showsMirroredPreview: Bool { savesMirrored || mirrorsPreviewOnly }
}
