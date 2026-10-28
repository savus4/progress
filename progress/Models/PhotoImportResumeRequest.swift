import Foundation

struct PhotoImportResumeRequest: Codable, Identifiable {
    let method: PhotoImportMethod
    let timelineID: UUID
    let createdAt: Date

    var id: UUID { timelineID }
}
