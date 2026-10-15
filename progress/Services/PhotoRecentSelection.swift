import Foundation

nonisolated struct PhotoRecentSelection: Sendable {
    let photos: [PhotoOfflinePhoto]
    let retainedAccessNames: Set<String>
    let byteCount: Int64
    let hasUnknownSizes: Bool

    init(photos: [PhotoOfflinePhoto], accessDates: [String: Date], metadata: [String: PhotoAssetMetadata], limitBytes: Int64, protectedNames: Set<String>) {
        let recent = photos.filter { photo in
            photo.fullImageAssetName.map { accessDates[$0] != nil } ?? false
        }.sorted {
            let lhs = accessDates[$0.fullImageAssetName ?? ""] ?? .distantPast
            let rhs = accessDates[$1.fullImageAssetName ?? ""] ?? .distantPast
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
        var selected: [PhotoOfflinePhoto] = []
        var accessNames: Set<String> = []
        var countedNames = protectedNames
        var bytes: Int64 = 0
        var unknown = false
        for photo in recent {
            guard let fullName = photo.fullImageAssetName else { continue }
            let names = photo.assetNames.subtracting(countedNames)
            let unknownSize = names.contains { metadata[$0] == nil }
            if unknownSize {
                unknown = true
                accessNames.insert(fullName)
                // Keep already downloaded parts within the budget while waiting
                // for the remaining sizes, including when iCloud is unavailable.
                if names.allSatisfy({ metadata[$0] == nil }) { continue }
            }
            var required: Int64 = 0
            for name in names {
                guard let size = metadata[name]?.byteCount else { continue }
                guard size >= 0, size <= Int64.max - required else { required = Int64.max; break }
                required += size
            }
            guard bytes <= limitBytes, required <= limitBytes - bytes else { continue }
            selected.append(photo)
            accessNames.insert(fullName)
            countedNames.formUnion(names)
            bytes += required
        }
        self.photos = selected
        retainedAccessNames = accessNames
        byteCount = bytes
        hasUnknownSizes = unknown
    }
}
