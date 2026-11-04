/// A shutter-time snapshot, retained through review and save retries.
nonisolated struct CameraMirroring: Sendable {
    let mirrorsPhotos: Bool
    let mirrorsPreviewOnly: Bool

    init(hirsModeEnabled: Bool, hirsModeProEnabled: Bool) {
        mirrorsPhotos = hirsModeProEnabled
        mirrorsPreviewOnly = hirsModeEnabled && !hirsModeProEnabled
    }

    var showsMirroredPreview: Bool { mirrorsPhotos || mirrorsPreviewOnly }
}
