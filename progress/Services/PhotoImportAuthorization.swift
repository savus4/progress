import Photos

enum PhotoImportAuthorization {
    @MainActor
    static func authorize(
        _ method: PhotoImportMethod,
        status: () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
        request: () async -> PHAuthorizationStatus = { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        // The private picker must never inspect or request library access.
        guard method.requiresFullAccess else { return true }

        let currentStatus = status()
        if currentStatus == .notDetermined {
            let requestedStatus = await request()
            return !Task.isCancelled && requestedStatus == .authorized
        }
        return currentStatus == .authorized
    }
}
