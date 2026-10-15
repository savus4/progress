import Foundation
import Testing
@testable import progress

struct CameraCaptureStateTests {
    @Test("Still and Live video callbacks can arrive in either order", arguments: [false, true])
    func pairsCallbacks(videoFirst: Bool) throws {
        var state = CameraCaptureState(captureID: 42)
        let data = Data("original HEIC".utf8)
        let video = URL(fileURLWithPath: "/tmp/capture.mov")
        if videoFirst { state.recordVideo(at: video, captureID: 42, errorMessage: nil) }
        state.recordPhoto(data: data, captureID: 42, errorMessage: nil)
        if !videoFirst { state.recordVideo(at: video, captureID: 42, errorMessage: nil) }

        let completion = state.finish(captureID: 42, errorMessage: nil)
        let result = try #require(completion)

        #expect(result.imageData == data)
        #expect(result.videoURL == video)
        #expect(result.errorMessage == nil)
        let duplicate = state.finish(captureID: 42, errorMessage: nil)
        #expect(duplicate == nil)
    }

    @Test("A failed Live movie preserves the valid still instead of hanging capture")
    func movieFailureKeepsStill() throws {
        var state = CameraCaptureState(captureID: 42)
        let data = Data("original still".utf8)
        state.recordVideo(at: URL(fileURLWithPath: "/tmp/failed.mov"), captureID: 42, errorMessage: "Movie failed")
        state.recordPhoto(data: data, captureID: 42, errorMessage: nil)

        let completion = state.finish(captureID: 42, errorMessage: "Movie failed")
        let result = try #require(completion)

        #expect(result.imageData == data)
        #expect(result.videoURL == nil)
        #expect(result.errorMessage == nil)
    }

    @Test("A failed still reports an error and never exposes an unpaired movie")
    func stillFailureDoesNotPublishVideo() throws {
        var state = CameraCaptureState(captureID: 42)
        state.recordVideo(at: URL(fileURLWithPath: "/tmp/unpaired.mov"), captureID: 42, errorMessage: nil)
        state.recordPhoto(data: nil, captureID: 42, errorMessage: "Still failed")

        let completion = state.finish(captureID: 42, errorMessage: nil)
        let result = try #require(completion)

        #expect(result.imageData == nil)
        #expect(result.videoURL == nil)
        #expect(result.errorMessage == "Still failed")
    }

    @Test("Callbacks from a different capture cannot overwrite or finish the active capture")
    func ignoresStaleCallbacks() throws {
        var state = CameraCaptureState(captureID: 42)
        state.recordPhoto(data: Data("wrong capture".utf8), captureID: 41, errorMessage: nil)
        state.recordVideo(at: URL(fileURLWithPath: "/tmp/wrong.mov"), captureID: 41, errorMessage: nil)
        let stale = state.finish(captureID: 41, errorMessage: nil)
        #expect(stale == nil)

        let completion = state.finish(captureID: 42, errorMessage: "Capture failed")
        let result = try #require(completion)

        #expect(result.imageData == nil)
        #expect(result.videoURL == nil)
        #expect(result.errorMessage == "Capture failed")
    }

    @Test("Empty photo data is a capture failure, not a savable photo")
    func rejectsEmptyPhoto() throws {
        var state = CameraCaptureState(captureID: 42)
        state.recordPhoto(data: Data(), captureID: 42, errorMessage: nil)
        let completion = state.finish(captureID: 42, errorMessage: nil)
        let result = try #require(completion)
        #expect(result.imageData == nil)
        #expect(result.errorMessage != nil)
    }
}
