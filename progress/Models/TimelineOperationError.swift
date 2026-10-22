import Foundation

nonisolated enum TimelineOperationError: LocalizedError {
    case lastTimeline
    case deleted
    case importInProgress

    var errorDescription: String? {
        switch self {
        case .lastTimeline: "Keep at least one timeline. Create another before deleting this one."
        case .deleted: "This timeline has been deleted. Choose another timeline."
        case .importInProgress: "Wait for the photo import to finish before deleting a timeline."
        }
    }
}
