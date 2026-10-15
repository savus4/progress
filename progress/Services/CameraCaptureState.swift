import Foundation

nonisolated struct CameraCaptureState: Sendable {
    struct Completion: Sendable {
        let imageData: Data?
        let videoURL: URL?
        let errorMessage: String?
    }

    let captureID: Int64
    let generation: UUID
    let requestedMovieURL: URL?
    private var imageData: Data?
    private var videoURL: URL?
    private var errorMessage: String?
    private var didFinish = false

    init(captureID: Int64, generation: UUID = UUID(), requestedMovieURL: URL? = nil) {
        self.captureID = captureID
        self.generation = generation
        self.requestedMovieURL = requestedMovieURL
    }

    mutating func recordPhoto(data: Data?, captureID: Int64, errorMessage: String?) {
        guard self.captureID == captureID, !didFinish else { return }
        if errorMessage == nil, let data, !data.isEmpty { imageData = data }
        else { self.errorMessage = errorMessage ?? "The camera didn’t return a photo." }
    }

    mutating func recordVideo(at url: URL, captureID: Int64, errorMessage: String?) {
        guard self.captureID == captureID, !didFinish else { return }
        if errorMessage == nil { videoURL = url }
        else { self.errorMessage = errorMessage }
    }

    mutating func finish(captureID: Int64, errorMessage: String?) -> Completion? {
        guard self.captureID == captureID, !didFinish else { return nil }
        didFinish = true
        return Completion(
            imageData: imageData, videoURL: imageData == nil ? nil : videoURL,
            errorMessage: imageData == nil ? (self.errorMessage ?? errorMessage ?? "The camera didn’t return a photo.") : nil
        )
    }
}
