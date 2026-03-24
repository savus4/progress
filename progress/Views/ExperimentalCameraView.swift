import SwiftUI
import AVFoundation
import CoreData
import CoreLocation

struct ExperimentalCameraView: View {
    @StateObject private var cameraService = CameraService()
    @StateObject private var locationService = LocationService()
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("eyeLinePosition") private var eyeLinePosition: Double = 0.35
    @AppStorage("mouthLinePosition") private var mouthLinePosition: Double = 0.65
    let gridTargetFrameInGlobal: CGRect?

    @State private var isEditingGuides = false
    @State private var isSaving = false
    @State private var showingCapturePreview = false
    @State private var pendingCaptureImage: UIImage?
    @State private var pendingCaptureImageData: Data?
    @State private var pendingLivePhotoImageData: Data?
    @State private var pendingLivePhotoVideoURL: URL?
    @State private var isCapturing = false
    @State private var isAnimatingPreviewToGrid = false

    private var controlsDisabled: Bool {
        isCapturing || isSaving || showingCapturePreview
    }

    var body: some View {
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let barContentHeight: CGFloat = 116
            let bottomBarHeight = barContentHeight + bottomInset
            let previewHeight = max(geometry.size.height - bottomBarHeight, 0)

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ZStack {
                        ExperimentalCameraPreviewView(session: cameraService.session)
                            .frame(maxWidth: .infinity)
                            .frame(height: previewHeight)
                            .background(Color.black)

                        ExperimentalGuidesOverlay(
                            eyeLinePosition: $eyeLinePosition,
                            mouthLinePosition: $mouthLinePosition,
                            isEditingGuides: $isEditingGuides,
                            isInteractionDisabled: controlsDisabled
                        )
                        .frame(height: previewHeight)
                        .allowsHitTesting(isEditingGuides && !controlsDisabled)
                    }
                    .contentShape(Rectangle())

                    experimentalControlBar(bottomInset: bottomInset, height: bottomBarHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showingCapturePreview, let pendingCaptureImage {
                    ExperimentalCapturePreviewOverlay(
                        image: pendingCaptureImage,
                        isSaving: isSaving,
                        isAnimatingToGrid: isAnimatingPreviewToGrid,
                        targetFrameInGlobal: gridTargetFrameInGlobal,
                        onRetake: retakeCapture,
                        onDone: confirmSave,
                        onDismiss: dismissCapturePreview
                    )
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity))
                    .zIndex(2)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard !isEditingGuides else { return }
                        guard value.translation.height > 100 else { return }

                        if showingCapturePreview {
                            dismissCapturePreview()
                        } else {
                            dismiss()
                        }
                    }
            )
        }
        .ignoresSafeArea()
        .task {
            await cameraService.checkAuthorization()
            if cameraService.isAuthorized {
                cameraService.setupCamera()
                cameraService.startSession()
            }

            locationService.requestPermission()
        }
        .onDisappear {
            cameraService.stopSession()
        }
        .onChange(of: cameraService.captureCompleted) { _, _ in
            if let capture = cameraService.livePhotoCapture {
                pendingCaptureImage = capture.image
                pendingCaptureImageData = capture.imageData
                pendingLivePhotoImageData = capture.imageData
                pendingLivePhotoVideoURL = capture.videoURL
                isAnimatingPreviewToGrid = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    showingCapturePreview = true
                }
                cameraService.stopSession()
            } else if let image = cameraService.capturedImage {
                pendingCaptureImage = image
                pendingCaptureImageData = cameraService.capturedImageData
                pendingLivePhotoImageData = nil
                pendingLivePhotoVideoURL = nil
                isAnimatingPreviewToGrid = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    showingCapturePreview = true
                }
                cameraService.stopSession()
            }
        }
        .onChange(of: cameraService.captureFinished) { _, _ in
            isCapturing = false
        }
    }

    @ViewBuilder
    private func experimentalControlBar(bottomInset: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black

            HStack(spacing: 20) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .disabled(controlsDisabled)

                Spacer()

                Button(action: capturePhoto) {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)

                        Circle()
                            .stroke(.white.opacity(0.96), lineWidth: 5)
                            .frame(width: 88, height: 88)
                    }
                }
                .accessibilityIdentifier("experimentalCameraShutter")
                .disabled(controlsDisabled)

                Spacer()

                Button(action: { isEditingGuides.toggle() }) {
                    VStack(spacing: 4) {
                        Image(systemName: isEditingGuides ? "slider.horizontal.3" : "eye")
                            .font(.title3)
                        Text(isEditingGuides ? "Done" : "Guides")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(isEditingGuides ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    )
                }
                .disabled(controlsDisabled)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, max(bottomInset, 14))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
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
        isAnimatingPreviewToGrid = false
        pendingCaptureImage = nil
        pendingCaptureImageData = nil
        pendingLivePhotoImageData = nil
        pendingLivePhotoVideoURL = nil
        withAnimation(.easeInOut(duration: 0.22)) {
            showingCapturePreview = false
        }
        cameraService.capturedImage = nil
        cameraService.capturedImageData = nil
        cameraService.livePhotoCapture = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            cameraService.startSession()
        }
    }

    private func dismissCapturePreview() {
        retakeCapture()
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
                isAnimatingPreviewToGrid = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                    pendingCaptureImage = nil
                    pendingCaptureImageData = nil
                    pendingLivePhotoImageData = nil
                    pendingLivePhotoVideoURL = nil
                    isAnimatingPreviewToGrid = false
                    dismiss()
                }
            }
        }
    }

    private func savePhoto(image: UIImage, imageData: Data?, livePhotoImageData: Data?, videoURL: URL?) async {
        isSaving = true
        defer {
            isSaving = false
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
            _ = try await PhotoStorageService.shared.savePhoto(
                image: image,
                imageData: imageData,
                livePhotoImageData: livePhotoImageData,
                livePhotoVideoURL: videoURL,
                location: location,
                context: viewContext
            )
        } catch {
            print("Error saving photo: \(error.localizedDescription)")
        }
    }
}

struct ExperimentalCapturePreviewOverlay: View {
    let image: UIImage
    let isSaving: Bool
    let isAnimatingToGrid: Bool
    let targetFrameInGlobal: CGRect?
    let onRetake: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    @State private var previewImageFrameInOverlay: CGRect = .zero
    @State private var animatedFrameInOverlay: CGRect = .zero

    var body: some View {
        GeometryReader { geometry in
            let fallbackTargetSize = min(150, max(100, (geometry.size.width - 4) / 3))
            let containerFrameInGlobal = geometry.frame(in: .global)
            let localTargetFrame: CGRect = {
                guard let targetFrameInGlobal,
                      targetFrameInGlobal != .zero else {
                    return CGRect(
                        x: 1,
                        y: geometry.safeAreaInsets.top + 1,
                        width: fallbackTargetSize,
                        height: fallbackTargetSize
                    )
                }

                return CGRect(
                    x: targetFrameInGlobal.minX - containerFrameInGlobal.minX,
                    y: targetFrameInGlobal.minY - containerFrameInGlobal.minY,
                    width: targetFrameInGlobal.width,
                    height: targetFrameInGlobal.height
                )
            }()
            let fallbackStartFrame = CGRect(
                x: 20,
                y: geometry.safeAreaInsets.top + 64,
                width: geometry.size.width - 40,
                height: max(geometry.size.width - 40, 1) * 1.25
            )

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(0.94)
                    .ignoresSafeArea()

                if !isAnimatingToGrid {
                    VStack(spacing: 18) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 46, height: 5)
                            .padding(.top, 14)

                        Text("Live Photo Preview")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.92))

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .padding(.horizontal, 20)
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(
                                            key: PreviewImageFramePreferenceKey.self,
                                            value: proxy.frame(in: .named("capturePreviewOverlay"))
                                        )
                                }
                            }

                        Text("Swipe down to dismiss")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))

                        HStack(spacing: 14) {
                            Button(action: onRetake) {
                                Text("Retake")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            .disabled(isSaving)

                            Button(action: onDone) {
                                if isSaving {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 15)
                                } else {
                                    Text("Done")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 15)
                                }
                            }
                            .foregroundStyle(.black)
                            .background(Color.white, in: Capsule())
                            .disabled(isSaving)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                    }
                    .padding(.top, geometry.safeAreaInsets.top + 24)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: animatedFrameInOverlay == .zero ? localTargetFrame.width : animatedFrameInOverlay.width,
                            height: animatedFrameInOverlay == .zero ? localTargetFrame.height : animatedFrameInOverlay.height
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .position(
                            x: (animatedFrameInOverlay == .zero ? localTargetFrame : animatedFrameInOverlay).midX,
                            y: (animatedFrameInOverlay == .zero ? localTargetFrame : animatedFrameInOverlay).midY
                        )
                        .onAppear {
                            let startFrame = previewImageFrameInOverlay == .zero ? fallbackStartFrame : previewImageFrameInOverlay
                            animatedFrameInOverlay = startFrame
                            withAnimation(.easeInOut(duration: 0.34)) {
                                animatedFrameInOverlay = localTargetFrame
                            }
                        }
                }
            }
            .coordinateSpace(name: "capturePreviewOverlay")
            .onPreferenceChange(PreviewImageFramePreferenceKey.self) { frame in
                if frame != .zero {
                    previewImageFrameInOverlay = frame
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !isAnimatingToGrid else { return }
                    if value.translation.height > 100 {
                        onDismiss()
                    }
                }
        )
    }
}

private struct PreviewImageFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct ExperimentalGuidesOverlay: View {
    @Binding var eyeLinePosition: Double
    @Binding var mouthLinePosition: Double
    @Binding var isEditingGuides: Bool
    let isInteractionDisabled: Bool

    private let minGap: Double = 0.05
    private let topMin: Double = 0.12
    private let bottomMax: Double = 0.86

    var body: some View {
        GeometryReader { geometry in
            let eyeY = geometry.size.height * eyeLinePosition
            let mouthY = geometry.size.height * mouthLinePosition

            ZStack {
                guideLine(color: .white.opacity(0.28), width: 1.5)
                    .frame(maxHeight: .infinity)

                faceLine(
                    y: eyeY,
                    title: "Eyes",
                    icon: "eye",
                    color: .white.opacity(0.85),
                    width: geometry.size.width,
                    showsLabel: isEditingGuides
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEditingGuides, !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                eyeLinePosition = min(max(normalized, topMin), mouthLinePosition - minGap)
                            }
                    )

                faceLine(
                    y: mouthY,
                    title: "Mouth",
                    icon: "mouth",
                    color: .white.opacity(0.85),
                    width: geometry.size.width,
                    showsLabel: isEditingGuides
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEditingGuides, !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                mouthLinePosition = max(min(normalized, bottomMax), eyeLinePosition + minGap)
                            }
                    )

                if isEditingGuides {
                    draggableHandle(title: "Eyes", y: eyeY, color: .white.opacity(0.92))
                    draggableHandle(title: "Mouth", y: mouthY, color: .white.opacity(0.92))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
    }

    private func guideLine(color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
            .frame(maxWidth: .infinity)
    }

    private func faceLine(
        y: CGFloat,
        title: String,
        icon: String,
        color: Color,
        width: CGFloat,
        showsLabel: Bool
    ) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.05), color, color.opacity(0.05)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width, height: 1.5)

            if showsLabel {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption2)
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.34), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.35), lineWidth: 1)
                )
            }
        }
        .position(x: width / 2, y: y)
    }

    private func draggableHandle(title: String, y: CGFloat, color: Color) -> some View {
        HStack {
            Spacer()
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(color, in: Capsule())
        }
        .position(x: 140, y: y - 24)
    }
}

struct ExperimentalCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect

        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session

        if let connection = uiView.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#Preview {
    ExperimentalCameraView(gridTargetFrameInGlobal: nil)
}
