import CoreData
import Observation

@MainActor
@Observable
final class PhotoDetailLibrarySaveState {
    private(set) var selectedObjectID: NSManagedObjectID?
    private var savedObjectIDs: Set<NSManagedObjectID> = []
    private let saveToLibrary: @MainActor (PhotoLibrarySaveItem) async throws -> Void

    var hasSavedCurrentPhoto: Bool {
        guard let selectedObjectID else { return false }
        return savedObjectIDs.contains(selectedObjectID)
    }

    init(
        initialObjectID: NSManagedObjectID?,
        saveToLibrary: @escaping @MainActor (PhotoLibrarySaveItem) async throws -> Void = { item in
            _ = try await PhotoLibrarySaveService.shared.save(item)
        }
    ) {
        selectedObjectID = initialObjectID
        self.saveToLibrary = saveToLibrary
    }

    func selectPhoto(_ objectID: NSManagedObjectID?) {
        selectedObjectID = objectID
    }

    func save(_ item: PhotoDetailItem) async throws {
        try await saveToLibrary(PhotoLibrarySaveItem(item: item))
        savedObjectIDs.insert(item.objectID)
    }
}
