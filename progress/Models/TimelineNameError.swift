import Foundation

nonisolated enum TimelineNameError: LocalizedError, Equatable {
    case empty
    case tooLong
    case duplicate

    var errorDescription: String? {
        switch self {
        case .empty: "Enter a name for this timeline."
        case .tooLong: "Choose a name with 80 characters or fewer."
        case .duplicate: "A timeline with this name already exists. Choose a different name."
        }
    }
}
