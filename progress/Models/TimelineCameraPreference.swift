import Foundation

/// Camera selection merges independently of names and Live Photo choices.
nonisolated struct TimelineCameraPreference: Equatable, Sendable {
    let position: CameraPosition
    let modifiedAt: Date?

    func supersedes(_ other: Self?) -> Bool {
        guard let other else { return true }
        let date = modifiedAt ?? .distantPast
        let otherDate = other.modifiedAt ?? .distantPast
        if date != otherDate { return date > otherDate }
        return position.rawValue > other.position.rawValue
    }
}
