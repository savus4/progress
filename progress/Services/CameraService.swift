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
    @Published var sensorAspectRatio: CGFloat = 4.0 / 3.0 // default fallback
    
    private let photoOutput = AVCapturePhotoOutput()
    private var livePhotoCompanionMovieURL: URL?
    private var isCapturingLivePhoto = false
    private var capturedPhotoData: Data?
    private var capturedStillImage: UIImage?
    
    override init() {
        super.init()
    }
    
    func checkAuthorization() async {
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
        
        // Determine sensor aspect ratio from videoDevice active format
        let formatDesc = videoDevice.activeFormat.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let width = CGFloat(dims.width)
        let height = CGFloat(dims.height)

        // The camera format dimensions are reported in landscape orientation.
        // Normalize to a portrait aspect ratio so SwiftUI can size the preview
        // as large as possible without cropping on the camera screen.
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        self.sensorAspectRatio = shortEdge / longEdge
        
        session.addInput(videoInput)
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            // Enable Live Photo capture
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        
        session.commitConfiguration()
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
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
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
