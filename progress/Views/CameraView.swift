import SwiftUI
import AVFoundation
import CoreData
import CoreLocation
import Combine

struct CameraView: View {
    @StateObject private var cameraService = CameraService()
    @StateObject private var locationService = LocationService()
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("eyeLinePosition") private var eyeLinePosition: Double = 0.35
    @AppStorage("mouthLinePosition") private var mouthLinePosition: Double = 0.65
    @AppStorage("showOverlay") private var showOverlay: Bool = false

    @State private var showingSettings = false
    @State private var isEditingGuides = false
    @State private var isSaving = false
    @State private var lastCapturedPhoto: DailyPhoto?
    @State private var overlayImage: UIImage?
    @State private var showingCapturePreview = false
    @State private var pendingCaptureImage: UIImage?
    @State private var pendingCaptureImageData: Data?
    @State private var pendingLivePhotoImageData: Data?
    @State private var pendingLivePhotoVideoURL: URL?
    @State private var isCapturing = false
    @State private var sensorAspectRatio: CGFloat = 4.0 / 3.0

    private var controlsDisabled: Bool {
        isCapturing || isSaving || showingCapturePreview
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(session: cameraService.session)
                    .aspectRatio(sensorAspectRatio, contentMode: .fit)
                    .background(Color.black)
                    .clipped()
                    .overlay(
                        DraggableGuidesOverlay(
                            eyeLinePosition: $eyeLinePosition,
                            mouthLinePosition: $mouthLinePosition,
                            isEditingGuides: $isEditingGuides,
                            isInteractionDisabled: controlsDisabled
                        )
                        .allowsHitTesting(isEditingGuides && !controlsDisabled)
                    )
                // Capture preview overlay (if active, covers everything)
                if showingCapturePreview, let pendingCaptureImage = pendingCaptureImage {
                    CapturePreviewOverlay(
                        image: pendingCaptureImage,
                        isSaving: isSaving,
                        onRetake: retakeCapture,
                        onSave: confirmSave
                    )
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar (never overlays preview)
            if !showingCapturePreview {
                controlBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .padding(.top, 8)
                    .background(Color.black)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .gesture(
            DragGesture()
                .onEnded { gesture in
                    if gesture.translation.height > 100 {
                        dismiss()
                    }
                }
        )
        .sheet(isPresented: $showingSettings) {
            AlignmentGuideSettingsView(
                eyeLinePosition: $eyeLinePosition,
                mouthLinePosition: $mouthLinePosition
            )
        }
        .task {
            await cameraService.checkAuthorization()
            if cameraService.isAuthorized {
                cameraService.setupCamera()
                cameraService.startSession()
            }

            locationService.requestPermission()

            // Load last photo for overlay
            await loadLastPhoto()
        }
        .onDisappear {
            cameraService.stopSession()
        }
        .onChange(of: cameraService.captureCompleted) { _, _ in
            // Handle capture completion
            if let capture = cameraService.livePhotoCapture {
                pendingCaptureImage = capture.image
                pendingCaptureImageData = capture.imageData
                pendingLivePhotoImageData = capture.imageData
                pendingLivePhotoVideoURL = capture.videoURL
                withAnimation(.easeInOut(duration: 0.25)) {
                    showingCapturePreview = true
                }
                cameraService.stopSession()
            } else if let image = cameraService.capturedImage {
                pendingCaptureImage = image
                pendingCaptureImageData = cameraService.capturedImageData
                pendingLivePhotoImageData = nil
                pendingLivePhotoVideoURL = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    showingCapturePreview = true
                }
                cameraService.stopSession()
            }
        }
        .onChange(of: cameraService.captureFinished) { _, _ in
            isCapturing = false
        }
        .onReceive(cameraService.$sensorAspectRatio) { ratio in
            sensorAspectRatio = ratio
        }
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .disabled(controlsDisabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: capturePhoto) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 70, height: 70)
                    Circle()
                        .stroke(.white.opacity(0.95), lineWidth: 4)
                        .frame(width: 84, height: 84)
                }
            }
            .disabled(controlsDisabled)
            .frame(maxWidth: .infinity)

            HStack {
                Spacer(minLength: 0)
                Button(action: { isEditingGuides.toggle() }) {
                    Image(systemName: isEditingGuides ? "lock.open" : "lock")
                        .font(.title2)
                        .foregroundStyle(isEditingGuides ? .yellow : .white)
                        .frame(width: 44, height: 44)
                }
                .disabled(controlsDisabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func capturePhoto() {
        guard !showingCapturePreview else { return }
        isCapturing = true
        let captureLocation = locationService.currentLocation
        #if targetEnvironment(simulator)
        cameraService.capturePhoto(withLivePhoto: false, location: captureLocation)
        #else
        cameraService.capturePhoto(withLivePhoto: true, location: captureLocation)
        #endif
    }

    private func retakeCapture() {
        pendingCaptureImage = nil
        pendingCaptureImageData = nil
        pendingLivePhotoImageData = nil
        pendingLivePhotoVideoURL = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showingCapturePreview = false
        }
        cameraService.capturedImage = nil
        cameraService.capturedImageData = nil
        cameraService.livePhotoCapture = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            cameraService.startSession()
        }
    }

    private func confirmSave() {
        guard let image = pendingCaptureImage else { return }

        Task {
            await savePhoto(
                image: image,
                imageData: pendingCaptureImageData,
                livePhotoImageData: pendingLivePhotoImageData,
                videoURL: pendingLivePhotoVideoURL
            )
            await MainActor.run {
                pendingCaptureImage = nil
                pendingCaptureImageData = nil
                pendingLivePhotoImageData = nil
                pendingLivePhotoVideoURL = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingCapturePreview = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    dismiss()
                }
            }
        }
    }

    private func savePhoto(image: UIImage, imageData: Data?, livePhotoImageData: Data?, videoURL: URL?) async {
        isSaving = true
        defer {
            isSaving = false
            // Reset camera service state after save
            Task { @MainActor in
                cameraService.capturedImage = nil
                cameraService.capturedImageData = nil
                cameraService.livePhotoCapture = nil
            }
        }

        let location: (latitude: Double, longitude: Double)?
        if let currentLocation = locationService.currentLocation {
            location = (currentLocation.coordinate.latitude, currentLocation.coordinate.longitude)
        } else {
            location = nil
        }

        do {
            let photo = try await PhotoStorageService.shared.savePhoto(
                image: image,
                imageData: imageData,
                livePhotoImageData: livePhotoImageData,
                livePhotoVideoURL: videoURL,
                location: location,
                context: viewContext
            )

            await MainActor.run {
                lastCapturedPhoto = photo
                overlayImage = image
                // Optionally dismiss or show success feedback
            }
        } catch {
            print("Error saving photo: \(error.localizedDescription)")
        }
    }

    private func loadLastPhoto() async {
        let fetchRequest = DailyPhoto.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: false)]
        fetchRequest.fetchLimit = 1

        do {
            let photos = try viewContext.fetch(fetchRequest)
            if let lastPhoto = photos.first,
               let thumbnailData = lastPhoto.thumbnailData,
               let thumbnail = UIImage(data: thumbnailData) {
                await MainActor.run {
                    overlayImage = thumbnail
                }
            }
        } catch {
            print("Error loading last photo: \(error.localizedDescription)")
        }
    }
}

struct CapturePreviewOverlay: View {
    let image: UIImage
    let isSaving: Bool
    let onRetake: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                Spacer()

                HStack(spacing: 16) {
                    Button(action: onRetake) {
                        Text("Retake")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(isSaving)

                    Button(action: onSave) {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        } else {
                            Text("Save")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .foregroundStyle(.white)
                    .background(.blue.gradient, in: Capsule())
                    .disabled(isSaving)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
    }
}

struct CameraControlSlot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
        }
        .frame(width: 92, height: 92)
    }
}

struct DraggableGuidesOverlay: View {
    @Binding var eyeLinePosition: Double
    @Binding var mouthLinePosition: Double
    @Binding var isEditingGuides: Bool
    let isInteractionDisabled: Bool

    private let minGap: Double = 0.15
    private let topMin: Double = 0.08
    private let bottomMax: Double = 0.92

    var body: some View {
        GeometryReader { geometry in
            let eyeY = geometry.size.height * eyeLinePosition
            let mouthY = geometry.size.height * mouthLinePosition

            ZStack {
                // Center line (always visible)
                Rectangle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)

                // Eye guide line (always visible, full width)
                Rectangle()
                    .fill(Color.gray.opacity(0.7))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
                    .position(x: geometry.size.width / 2, y: eyeY)

                // Mouth guide line (always visible, full width)
                Rectangle()
                    .fill(Color.gray.opacity(0.7))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
                    .position(x: geometry.size.width / 2, y: mouthY)

                // Handles (only visible when editing, positioned on the left)
                if isEditingGuides {
                    guideHandle(
                        width: geometry.size.width,
                        y: eyeY,
                        icon: "eye",
                        label: "Eyes"
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                let upperBound = mouthLinePosition - minGap
                                eyeLinePosition = min(max(normalized, topMin), upperBound)
                            }
                    )

                    guideHandle(
                        width: geometry.size.width,
                        y: mouthY,
                        icon: "mouth",
                        label: "Mouth"
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                let lowerBound = eyeLinePosition + minGap
                                mouthLinePosition = max(min(normalized, bottomMax), lowerBound)
                            }
                    )
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func guideHandle(width: CGFloat, y: CGFloat, icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .position(x: 50, y: y)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(previewLayer)

        context.coordinator.previewLayer = previewLayer

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let previewLayer = context.coordinator.previewLayer else { return }

            previewLayer.frame = uiView.bounds

            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

struct AlignmentGuideSettingsView: View {
    @Binding var eyeLinePosition: Double
    @Binding var mouthLinePosition: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Eye Line Position") {
                    VStack {
                        Slider(value: $eyeLinePosition, in: 0.1...0.5)
                        Text("Position: \(Int(eyeLinePosition * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Mouth Line Position") {
                    VStack {
                        Slider(value: $mouthLinePosition, in: 0.5...0.9)
                        Text("Position: \(Int(mouthLinePosition * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Reset to Default") {
                        eyeLinePosition = 0.35
                        mouthLinePosition = 0.65
                    }
                }
            }
            .navigationTitle("Alignment Guides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
