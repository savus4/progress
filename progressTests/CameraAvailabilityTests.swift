import AVFoundation
import Combine
import Testing
@testable import progress

@MainActor
struct CameraAvailabilityTests {
    @Test("Audio preparation does not enable a shutter without a video session")
    func audioPreparationDoesNotMakeCameraReady() async {
        let camera = CameraService()

        await camera.configureLivePhotoAudio(enabled: false)

        #expect(!camera.isReadyForCapture)
        #expect(camera.captureErrorMessage == nil)
    }

    @Test("Starting without a camera reports an error and keeps capture disabled", .timeLimit(.minutes(1)))
    func unavailableSessionDoesNotBecomeReady() async {
        let camera = CameraService()
        defer { camera.stopSession() }

        camera.startSession()
        for await _ in camera.$captureErrorMessage.first(where: { $0 != nil }).values {
            break
        }

        #expect(!camera.isReadyForCapture)
        #expect(!camera.session.isRunning)
        #expect(camera.captureErrorMessage?.isEmpty == false)
    }

    @Test("Capture without a video connection fails safely and allows another attempt",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func captureWithoutConnectionIsRecoverable(withLivePhoto: Bool) async {
        let camera = CameraService()

        for attempt in 1...2 {
            camera.capturePhoto(withLivePhoto: withLivePhoto)
            for await _ in camera.$captureFinished.first(where: { $0 == attempt }).values {
                break
            }

            #expect(camera.captureFinished == attempt)
            #expect(camera.captureCompleted == 0)
            #expect(camera.captureErrorMessage?.isEmpty == false)
            #expect(!camera.isReadyForCapture)
            #expect(camera.capturedImage == nil)
            #expect(camera.capturedImageData == nil)
            #expect(camera.livePhotoCapture == nil)
        }
    }
}
