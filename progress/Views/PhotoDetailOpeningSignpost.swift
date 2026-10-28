import os

@MainActor
final class PhotoDetailOpeningSignpost {
    private let signposter = OSSignposter(subsystem: "me.riepl.progress", category: .pointsOfInterest)
    private var interval: OSSignpostIntervalState?

    func begin() {
        guard interval == nil else { return }
        interval = signposter.beginInterval("Photo Opening")
    }

    func end() {
        guard let interval else { return }
        signposter.endInterval("Photo Opening", interval)
        self.interval = nil
    }
}
