import SwiftUI
@preconcurrency import AVFoundation
import UIKit
import Combine
import CoreLocation
import ImageIO

@MainActor
final class CameraService: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isAuthorized = false
    @Published private(set) var isReadyForCapture = false
    @Published private(set) var livePhotoAudioUnavailable = false
    private var audioConfigurationID = UUID()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage?
    @Published var capturedImageData: Data?
    @Published var livePhotoCapture: (image: UIImage, imageData: Data, videoURL: URL)?
    @Published var captureCompleted: Int = 0
    @Published var captureFinished: Int = 0
    @Published var sensorAspectRatio: CGFloat
    @Published var isLivePhotoCaptureSupported = false
    
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated private let sessionQueue = DispatchQueue(
        label: "me.riepl.progress.camera-session",
        qos: .userInitiated
    )
    nonisolated(unsafe) private var livePhotoCompanionMovieURL: URL?
    nonisolated(unsafe) private var isCapturingLivePhoto = false
    nonisolated(unsafe) private var capturedPhotoData: Data?
    nonisolated(unsafe) private var capturedStillImage: UIImage?
    private let processInfo = ProcessInfo.processInfo
    nonisolated static let defaultPortraitPhotoAspectRatio: CGFloat = 3.0 / 4.0
    
    override init() {
        self.sensorAspectRatio = Self.defaultPortraitPhotoAspectRatio
        super.init()
    }

    nonisolated static func preferredCodec(from availableCodecs: [AVVideoCodecType]) -> AVVideoCodecType? {
        availableCodecs.contains(.hevc) ? .hevc : nil
    }
    
    func checkAuthorization() async {
        if usesMockCapture {
            await MainActor.run {
                isAuthorized = true
            }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await MainActor.run {
                isAuthorized = true
            }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                isAuthorized = granted
            }
        default:
            await MainActor.run {
                isAuthorized = false
            }
        }
    }
    
    func setupCamera() async {
        let configuration = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: configureCameraOnSessionQueue())
            }
        }
        sensorAspectRatio = configuration.sensorAspectRatio
        isLivePhotoCaptureSupported = configuration.isLivePhotoCaptureSupported
    }

    func configureLivePhotoAudio(enabled: Bool) async {
        let configurationID = UUID()
        audioConfigurationID = configurationID
        isReadyForCapture = false
        let needsAudio = enabled && isLivePhotoCaptureSupported && !usesMockCapture
        let authorized = await CameraMicrophonePermission.authorize(
            enabled: needsAudio,
            status: { AVCaptureDevice.authorizationStatus(for: .audio) },
            request: { await AVCaptureDevice.requestAccess(for: .audio) }
        )
        guard !Task.isCancelled, audioConfigurationID == configurationID else { return }
        let connected = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: configureAudioInputOnSessionQueue(enabled: authorized))
            }
        }
        guard !Task.isCancelled, audioConfigurationID == configurationID else { return }
        livePhotoAudioUnavailable = needsAudio && !connected
        isReadyForCapture = true
    }

    nonisolated private func configureAudioInputOnSessionQueue(enabled: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let audioInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.audio) }
        // Recheck here: never create a microphone input before authorization.
        guard enabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            for input in audioInputs { session.removeInput(input) }
            return false
        }
        if !audioInputs.isEmpty { return true }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    nonisolated private func configureCameraOnSessionQueue() -> (
        sensorAspectRatio: CGFloat,
        isLivePhotoCaptureSupported: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if session.outputs.contains(photoOutput) {
            return (Self.portraitPhotoAspectRatio(for: photoOutput.maxPhotoDimensions),
                    photoOutput.isLivePhotoCaptureSupported)
        }
        session.beginConfiguration()
        
        // Set session preset for high quality
        session.sessionPreset = .photo
        
        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            return (Self.defaultPortraitPhotoAspectRatio, false)
        }
        
        session.addInput(videoInput)
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // Enable Live Photo capture
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        
        session.commitConfiguration()
        return (
            Self.portraitPhotoAspectRatio(for: photoOutput.maxPhotoDimensions),
            photoOutput.isLivePhotoCaptureSupported
        )
    }

    nonisolated static func portraitPhotoAspectRatio(for dimensions: CMVideoDimensions) -> CGFloat {
        let width = CGFloat(dimensions.width)
        let height = CGFloat(dimensions.height)
        guard width > 0, height > 0 else {
            return defaultPortraitPhotoAspectRatio
        }

        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        return shortEdge / longEdge
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        audioConfigurationID = UUID()
        isReadyForCapture = false
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto(withLivePhoto: Bool = true, location: CLLocation? = nil) {
        if usesMockCapture {
            simulateMockCapture(location: location)
            return
        }

        capturedImage = nil
        capturedImageData = nil
        livePhotoCapture = nil

        let locationSnapshot = location.map {
            CameraLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        sessionQueue.async { [weak self] in
            self?.capturePhotoOnSessionQueue(
                withLivePhoto: withLivePhoto,
                location: locationSnapshot
            )
        }
    }

    nonisolated private func capturePhotoOnSessionQueue(
        withLivePhoto: Bool,
        location: CameraLocation?
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        let settings: AVCapturePhotoSettings
        if let preferredPhotoCodec = Self.preferredCodec(from: photoOutput.availablePhotoCodecTypes) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: preferredPhotoCodec])
        } else {
            settings = AVCapturePhotoSettings()
        }

        if let location {
            settings.metadata = [
                kCGImagePropertyGPSDictionary as String: Self.gpsMetadataDictionary(for: location)
            ]
        }

        capturedPhotoData = nil
        capturedStillImage = nil

        #if targetEnvironment(simulator)
        livePhotoCompanionMovieURL = nil
        isCapturingLivePhoto = false
        #else
        let shouldCaptureLivePhoto = withLivePhoto && photoOutput.isLivePhotoCaptureSupported

        if shouldCaptureLivePhoto {
            let livePhotoMovieFilePath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            settings.livePhotoMovieFileURL = livePhotoMovieFilePath
            if let preferredLivePhotoCodec = Self.preferredCodec(from: photoOutput.availableLivePhotoVideoCodecTypes) {
                settings.livePhotoVideoCodecType = preferredLivePhotoCodec
            }
            livePhotoCompanionMovieURL = livePhotoMovieFilePath
            isCapturingLivePhoto = true
        } else {
            livePhotoCompanionMovieURL = nil
            isCapturingLivePhoto = false
        }
        #endif

        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func simulateMockCapture(location: CLLocation?) {
        capturedImage = nil
        capturedImageData = nil
        livePhotoCapture = nil
        capturedPhotoData = nil
        capturedStillImage = nil
        livePhotoCompanionMovieURL = nil
        isCapturingLivePhoto = false

        let size = CGSize(width: 1200, height: 1600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 96),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
            let text = "UI TEST"
            let rect = CGRect(x: 0, y: size.height / 2 - 60, width: size.width, height: 120)
            text.draw(in: rect, withAttributes: attributes)
        }

        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        capturedPhotoData = data
        capturedStillImage = image

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.capturedImage = image
            self.capturedImageData = data
            self.captureFinished += 1
            self.captureCompleted += 1
        }
    }

    private var usesMockCapture: Bool {
        processInfo.arguments.contains("UI_TEST_MOCK_CAPTURE")
            || processInfo.environment["UI_TEST_MOCK_CAPTURE"] == "1"
    }

    nonisolated private static func gpsMetadataDictionary(for location: CameraLocation) -> [String: Any] {
        return [
            kCGImagePropertyGPSLatitudeRef as String: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLatitude as String: abs(location.latitude),
            kCGImagePropertyGPSLongitudeRef as String: location.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSLongitude as String: abs(location.longitude)
        ]
    }
    
    func switchCamera() {
        sessionQueue.async { [weak self] in
            self?.switchCameraOnSessionQueue()
        }
    }

    nonisolated private func switchCameraOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        session.beginConfiguration()
        
        // Remove current input
        guard let currentInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            session.commitConfiguration()
            return
        }
        
        session.removeInput(currentInput)
        
        // Add new input with opposite position
        let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice),
              session.canAddInput(newInput) else {
            // If we can't switch, re-add the current input
            session.addInput(currentInput)
            session.commitConfiguration()
            return
        }
        
        session.addInput(newInput)
        session.commitConfiguration()
    }
}

private struct CameraLocation: Sendable {
    let latitude: Double
    let longitude: Double
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async { [weak self] in
            self?.handleProcessedPhoto(photo, error: error)
        }
    }

    nonisolated private func handleProcessedPhoto(_ photo: AVCapturePhoto, error: Error?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard error == nil,
              let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("Error capturing photo: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        // Keep still data/image immediately for Live Photo pairing callback.
        capturedPhotoData = imageData
        capturedStillImage = image

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.capturedImage = image
            self.capturedImageData = imageData
            
            // If not capturing Live Photo, trigger save immediately
            if !self.isCapturingLivePhoto {
                self.captureCompleted += 1
            }
        }
    }
    
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            self?.handleProcessedLivePhoto(at: outputFileURL, error: error)
        }
    }

    nonisolated private func handleProcessedLivePhoto(at outputFileURL: URL, error: Error?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard error == nil else {
            print("Error processing Live Photo video: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        // Store the video URL with the paired still image.
        if let image = capturedStillImage {
            let stillData = capturedPhotoData ?? (image.jpegData(compressionQuality: 1.0) ?? Data())
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.capturedImage = image
                self.capturedImageData = stillData
                self.livePhotoCapture = (image: image, imageData: stillData, videoURL: outputFileURL)
                self.captureCompleted += 1
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        Task { @MainActor [weak self] in
            self?.captureFinished += 1
        }
    }
}
