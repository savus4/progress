import Foundation

/// An independent clock prevents name edits from overwriting camera choices.
nonisolated struct TimelineLivePhotoPreference: Equatable, Sendable {
    let isEnabled: Bool
    let modifiedAt: Date?

    func supersedes(_ other: Self?) -> Bool {
        guard let other else { return true }
        let date = modifiedAt ?? .distantPast
        let otherDate = other.modifiedAt ?? .distantPast
        if date != otherDate { return date > otherDate }
        // Deterministic tie resolution for duplicate metadata imported offline.
        return !isEnabled && other.isEnabled
    }
}
