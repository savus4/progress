enum PhotoImportMethod: String, CaseIterable, Codable, Identifiable {
    case photos
    case privatePhotos
    case album

    var id: Self { self }

    var title: String {
        switch self {
        case .photos: "Import Photos"
        case .privatePhotos: "Import Photos Privately"
        case .album: "Import Album"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .privatePhotos: "lock.shield"
        case .album: "rectangle.stack"
        }
    }

    var requiresFullAccess: Bool { self != .privatePhotos }
}
