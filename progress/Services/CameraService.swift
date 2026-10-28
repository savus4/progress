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
    private var sessionConfigurationID = UUID()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage?
    @Published var capturedImageData: Data?
    @Published var livePhotoCapture: (image: UIImage, imageData: Data, videoURL: URL)?
    @Published var captureCompleted: Int = 0
    @Published var captureFinished: Int = 0
    @Published var sensorAspectRatio: CGFloat
    @Published var isLivePhotoCaptureSupported = false
    @Published private(set) var cameraPosition: CameraPosition = .front
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isConfiguringCamera = false
    @Published private(set) var captureErrorMessage: String?
    private var captureInFlight = false
    private var captureGeneration = UUID()
    
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated private let sessionQueue = DispatchQueue(
        label: "me.riepl.progress.camera-session",
        qos: .userInitiated
    )
    nonisolated(unsafe) private var captureState: CameraCaptureState?
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
    
    func setupCamera(position: CameraPosition = .front) async {
        let configurationID = UUID()
        sessionConfigurationID = configurationID
        isConfiguringCamera = true
        isReadyForCapture = false
        let configuration = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: configureCameraOnSessionQueue(position: position))
            }
        }
        guard sessionConfigurationID == configurationID else { return }
        isConfiguringCamera = false
        guard !Task.isCancelled else { return }
        sensorAspectRatio = configuration.sensorAspectRatio
        isLivePhotoCaptureSupported = configuration.isLivePhotoCaptureSupported
        cameraPosition = configuration.position ?? position
        canSwitchCamera = Self.captureDevice(for: .front) != nil && Self.captureDevice(for: .back) != nil
    }

    func configureLivePhotoAudio(enabled: Bool) async {
        let configurationID = UUID()
        sessionConfigurationID = configurationID
        // Keep the shutter disabled until startSession verifies the video connection.
        isReadyForCapture = false
        let needsAudio = enabled && isLivePhotoCaptureSupported && !usesMockCapture
        let authorized = await CameraMicrophonePermission.authorize(
            enabled: needsAudio,
            status: { AVCaptureDevice.authorizationStatus(for: .audio) },
            request: { await AVCaptureDevice.requestAccess(for: .audio) }
        )
        guard !Task.isCancelled, sessionConfigurationID == configurationID else { return }
        let connected = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: configureAudioInputOnSessionQueue(enabled: authorized))
            }
        }
        guard !Task.isCancelled, sessionConfigurationID == configurationID else { return }
        livePhotoAudioUnavailable = needsAudio && !connected
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

    nonisolated static func captureDevice(for position: CameraPosition) -> AVCaptureDevice? {
        AVCaptureDevice.default(position.captureDeviceType, for: .video, position: position.captureDevicePosition)
    }

    nonisolated private func configureCameraOnSessionQueue(position: CameraPosition) -> (
        sensorAspectRatio: CGFloat,
        isLivePhotoCaptureSupported: Bool,
        position: CameraPosition?
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        // Set session preset for high quality
        session.sessionPreset = .photo
        
        let videoInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        if videoInputs.first?.device.position != position.captureDevicePosition,
           let device = Self.captureDevice(for: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            for previous in videoInputs { session.removeInput(previous) }
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                // Leave the working camera intact if a replacement cannot be connected.
                for previous in videoInputs where session.canAddInput(previous) { session.addInput(previous) }
            }
        }
        
        // Add photo output
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        // Capabilities can change with the input, even when the output is reused.
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
        photoOutput.maxPhotoQualityPrioritization = .quality
        let activeDevice = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?.device
        let activePosition: CameraPosition? = activeDevice.map { $0.position == .back ? .back : .front }
        return (
            Self.portraitPhotoAspectRatio(for: photoOutput.maxPhotoDimensions),
            photoOutput.isLivePhotoCaptureSupported,
            activePosition
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
        let configurationID = sessionConfigurationID
        isReadyForCapture = false
        captureErrorMessage = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.photoOutput.connection(with: .video) != nil, !self.session.isRunning {
                self.session.startRunning()
            }
            let isReady = self.canCapturePhotoOnSessionQueue
            Task { @MainActor [weak self] in
                guard let self, self.sessionConfigurationID == configurationID else { return }
                self.isReadyForCapture = isReady
                if !isReady {
                    self.captureErrorMessage = Self.cameraUnavailableMessage
                }
            }
        }
    }

    func stopSession() {
        sessionConfigurationID = UUID()
        isConfiguringCamera = false
        isReadyForCapture = false
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto(withLivePhoto: Bool = true, location: CLLocation? = nil) {
        guard !captureInFlight else { return }
        captureInFlight = true
        captureErrorMessage = nil
        captureGeneration = UUID()
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
        let generation = captureGeneration
        sessionQueue.async { [weak self] in
            self?.capturePhotoOnSessionQueue(
                withLivePhoto: withLivePhoto,
                location: locationSnapshot,
                generation: generation
            )
        }
    }

    nonisolated private func capturePhotoOnSessionQueue(
        withLivePhoto: Bool,
        location: CameraLocation?,
        generation: UUID
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        // AVFoundation raises an Objective-C exception for a missing/inactive
        // connection; Swift error handling and capture delegates can't catch it.
        guard canCapturePhotoOnSessionQueue else {
            Task { @MainActor [weak self] in
                guard let self, self.captureGeneration == generation else { return }
                self.captureInFlight = false
                self.isReadyForCapture = false
                self.captureErrorMessage = Self.cameraUnavailableMessage
                self.captureFinished += 1
            }
            return
        }

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

        #if !targetEnvironment(simulator)
        let shouldCaptureLivePhoto = withLivePhoto && photoOutput.isLivePhotoCaptureSupported

        if shouldCaptureLivePhoto {
            let livePhotoMovieFilePath = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            settings.livePhotoMovieFileURL = livePhotoMovieFilePath
            if let preferredLivePhotoCodec = Self.preferredCodec(from: photoOutput.availableLivePhotoVideoCodecTypes) {
                settings.livePhotoVideoCodecType = preferredLivePhotoCodec
            }
        }
        #endif

        captureState = CameraCaptureState(
            captureID: settings.uniqueID, generation: generation,
            requestedMovieURL: settings.livePhotoMovieFileURL
        )
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated private var canCapturePhotoOnSessionQueue: Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard session.isRunning, !session.isInterrupted,
              session.outputs.contains(photoOutput),
              let connection = photoOutput.connection(with: .video) else { return false }
        return connection.isEnabled && connection.isActive
    }

    nonisolated private static var cameraUnavailableMessage: String {
        #if targetEnvironment(simulator)
        "Camera capture isn’t available in the simulator. Use an iPhone to take a photo."
        #else
        "The camera isn’t available right now. Close the camera and try again."
        #endif
    }

    private func simulateMockCapture(location: CLLocation?) {
        capturedImage = nil
        capturedImageData = nil
        livePhotoCapture = nil

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

        guard let data = image.jpegData(compressionQuality: 0.95) else {
            captureInFlight = false
            captureErrorMessage = "The camera didn’t return a photo."
            captureFinished += 1
            return
        }
        let generation = captureGeneration

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard self.captureGeneration == generation else { return }
            self.captureInFlight = false
            self.capturedImage = image
            self.capturedImageData = data
            self.captureFinished += 1
            self.captureCompleted += 1
        }
    }

    func discardCapture() {
        captureGeneration = UUID()
        if let videoURL = livePhotoCapture?.videoURL { try? FileManager.default.removeItem(at: videoURL) }
        capturedImage = nil
        capturedImageData = nil
        livePhotoCapture = nil
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
        captureState?.recordPhoto(
            data: error == nil ? photo.fileDataRepresentation() : nil,
            captureID: photo.resolvedSettings.uniqueID, errorMessage: error?.localizedDescription
        )
    }
    
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            self?.handleProcessedLivePhoto(at: outputFileURL, captureID: resolvedSettings.uniqueID, error: error)
        }
    }

    nonisolated private func handleProcessedLivePhoto(at outputFileURL: URL, captureID: Int64, error: Error?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard captureState?.captureID == captureID else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        captureState?.recordVideo(at: outputFileURL, captureID: captureID, errorMessage: error?.localizedDescription)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            self?.finishCapture(captureID: resolvedSettings.uniqueID, error: error)
        }
    }

    nonisolated private func finishCapture(captureID: Int64, error: Error?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard var state = captureState,
              let completion = state.finish(captureID: captureID, errorMessage: error?.localizedDescription) else { return }
        captureState = nil
        let image = completion.imageData.flatMap { UIImage(data: $0) }
        if image == nil || completion.videoURL == nil, let movieURL = state.requestedMovieURL {
            try? FileManager.default.removeItem(at: movieURL)
        }
        let generation = state.generation
        Task { @MainActor [weak self] in
            self?.captureInFlight = false
            guard let self, self.captureGeneration == generation else {
                if let videoURL = completion.videoURL { try? FileManager.default.removeItem(at: videoURL) }
                return
            }
            if let image, let data = completion.imageData {
                self.capturedImage = image
                self.capturedImageData = data
                if let videoURL = completion.videoURL {
                    self.livePhotoCapture = (image: image, imageData: data, videoURL: videoURL)
                }
                self.captureCompleted += 1
            } else {
                self.captureErrorMessage = completion.errorMessage ?? "The captured photo couldn’t be read. Please try again."
            }
            self.captureFinished += 1
        }
    }
}
