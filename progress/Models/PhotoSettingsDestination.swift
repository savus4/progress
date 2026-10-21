enum PhotoSettingsDestination: String, Hashable, Identifiable {
    case general
    case photoStorage
    case storageManagement

    var id: Self { self }
}
