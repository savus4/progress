import SwiftUI
import AVFoundation
import UIKit
import Combine
import CoreLocation
import ImageIO

class CameraService: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var session = AVCaptureSession()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage?
    @Published var capturedImageData: Data?
    @Published var livePhotoCapture: (image: UIImage, imageData: Data, videoURL: URL)?
    @Published var captureCompleted: Int = 0
    @Published var captureFinished: Int = 0
    @Published var sensorAspectRatio: CGFloat
    @Published var isLivePhotoCaptureSupported = false
    
    private let photoOutput = AVCapturePhotoOutput()
    private var livePhotoCompanionMovieURL: URL?
    private var isCapturingLivePhoto = false
    private var capturedPhotoData: Data?
    private var capturedStillImage: UIImage?
    private let processInfo = ProcessInfo.processInfo
    static let defaultPortraitPhotoAspectRatio: CGFloat = 3.0 / 4.0
    
    override init() {
        self.sensorAspectRatio = Self.defaultPortraitPhotoAspectRatio
        super.init()
    }

    static func preferredCodec(from availableCodecs: [AVVideoCodecType]) -> AVVideoCodecType? {
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
    
    func setupCamera() {
        isLivePhotoCaptureSupported = false
        session.beginConfiguration()
        
        // Set session preset for high quality
        session.sessionPreset = .photo
        
        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            return
        }
        
        session.addInput(videoInput)
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            sensorAspectRatio = Self.portraitPhotoAspectRatio(for: photoOutput.maxPhotoDimensions)

            // Enable Live Photo capture
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
            isLivePhotoCaptureSupported = photoOutput.isLivePhotoCaptureSupported
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        
        session.commitConfiguration()
    }

    static func portraitPhotoAspectRatio(for dimensions: CMVideoDimensions) -> CGFloat {
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
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }
    }
    
    func stopSession() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.stopRunning()
            }
        }
    }
    
    func capturePhoto(withLivePhoto: Bool = true, location: CLLocation? = nil) {
        if usesMockCapture {
            simulateMockCapture(location: location)
            return
        }

        let settings: AVCapturePhotoSettings
        if let preferredPhotoCodec = Self.preferredCodec(from: photoOutput.availablePhotoCodecTypes) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: preferredPhotoCodec])
        } else {
            settings = AVCapturePhotoSettings()
        }

        if let location {
            settings.metadata = [kCGImagePropertyGPSDictionary as String: gpsMetadataDictionary(for: location)]
        }
        
        // Reset previous capture
        capturedImage = nil
        capturedImageData = nil
        livePhotoCapture = nil
        capturedPhotoData = nil
        capturedStillImage = nil
        
        // Configure Live Photo if supported and requested.
        // Simulator camera pipelines often don't produce valid paired metadata.
        #if targetEnvironment(simulator)
        livePhotoCompanionMovieURL = nil
        isCapturingLivePhoto = false
        #else
        let shouldCaptureLivePhoto = withLivePhoto && photoOutput.isLivePhotoCaptureSupported

        if shouldCaptureLivePhoto {
            let livePhotoMovieFileName = UUID().uuidString
            let livePhotoMovieFilePath = FileManager.default.temporaryDirectory
                .appendingPathComponent(livePhotoMovieFileName)
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

    private func gpsMetadataDictionary(for location: CLLocation) -> [String: Any] {
        let coordinate = location.coordinate
        return [
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude)
        ]
    }
    
    func switchCamera() {
        session.beginConfiguration()
        
        // Remove current input
        guard let currentInput = session.inputs.first as? AVCaptureDeviceInput else {
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

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("Error capturing photo: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        // Keep still data/image immediately for Live Photo pairing callback.
        self.capturedPhotoData = imageData
        self.capturedStillImage = image

        DispatchQueue.main.async {
            self.capturedImage = image
            self.capturedImageData = imageData
            
            // If not capturing Live Photo, trigger save immediately
            if !self.isCapturingLivePhoto {
                self.captureCompleted += 1
            }
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error == nil else {
            print("Error processing Live Photo video: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        // Store the video URL with the paired still image.
        if let image = self.capturedStillImage {
            let stillData = self.capturedPhotoData ?? (image.jpegData(compressionQuality: 1.0) ?? Data())
            DispatchQueue.main.async {
                self.capturedImage = image
                self.capturedImageData = stillData
                self.livePhotoCapture = (image: image, imageData: stillData, videoURL: outputFileURL)
                self.captureCompleted += 1
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async {
            self.captureFinished += 1
        }
    }
}
