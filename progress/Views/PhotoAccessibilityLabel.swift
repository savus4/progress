import Foundation

enum PhotoAccessibilityLabel {
    static func make(captureDate: Date?, locationName: String?, isLivePhoto: Bool = false) -> String {
        var components = [isLivePhoto ? "Live Photo" : "Photo"]
        if let captureDate {
            components.append(captureDate.formatted(date: .long, time: .shortened))
        }
        if let locationName, !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.append(locationName)
        }
        return components.joined(separator: ", ")
    }
}
