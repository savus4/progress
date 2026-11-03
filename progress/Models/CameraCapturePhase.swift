import Foundation

nonisolated enum CameraCapturePhase: Equatable, Sendable {
    case takingPhoto
    case recordingLivePhoto
    case processingCapture

    var title: String {
        switch self {
        case .takingPhoto: "Taking Photo"
        case .recordingLivePhoto: "Recording Live Photo"
        case .processingCapture: "Processing Capture"
        }
    }

    var detail: String {
        switch self {
        case .takingPhoto, .recordingLivePhoto: "Hold steady for a moment."
        case .processingCapture: "Preparing your preview."
        }
    }

    var symbolName: String {
        switch self {
        case .takingPhoto: "camera"
        case .recordingLivePhoto: "livephoto"
        case .processingCapture: "hourglass"
        }
    }
}
