import SwiftUI
import AVFoundation
import CoreData
import CoreLocation

struct ExperimentalCameraView: View {
    private enum CaptureFeedbackStage {
        case recordingLivePhoto
        case processingCapture

        var title: String {
            switch self {
            case .recordingLivePhoto:
                return "Recording Live Photo"
            case .processingCapture:
                return "Processing Capture"
            }
        }

        var detail: String {
            switch self {
            case .recordingLivePhoto:
                return "Hold steady for a moment."
            case .processingCapture:
                return "Preparing your preview."
            }
        }

        var symbolName: String {
            switch self {
            case .recordingLivePhoto:
                return "livephoto"
            case .processingCapture:
                return "hourglass"
            }
        }
    }

    @StateObject private var cameraService = CameraService()
    @StateObject private var locationService = LocationService()
    @ObservedObject private var alignmentGuideStore = AlignmentGuideStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    let gridTargetFrameInGlobal: CGRect?

    @State private var isEditingGuides = false
    @State private var isSaving = false
    @State private var showingCapturePreview = false
    @State private var pendingCaptureImage: UIImage?
    @State private var pendingCaptureImageData: Data?
    @State private var pendingLivePhotoImageData: Data?
    @State private var pendingLivePhotoImageURL: URL?
    @State private var pendingLivePhotoVideoURL: URL?
    @State private var isCapturing = false
    @State private var isAnimatingPreviewToGrid = false
    @State private var captureFeedbackStage: CaptureFeedbackStage?
    @State private var draftEyeLinePosition: Double?
    @State private var draftMouthLinePosition: Double?
    private let processInfo = ProcessInfo.processInfo

    private var guideInteractionDisabled: Bool {
        isCapturing || isSaving || showingCapturePreview || captureFeedbackStage != nil
    }

    private var controlsDisabled: Bool {
        guideInteractionDisabled || isEditingGuides
    }

    var body: some View {
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let barContentHeight: CGFloat = 116
            let bottomBarHeight = barContentHeight + bottomInset
            let previewHeight = max(geometry.size.height - bottomBarHeight, 0)
            let previewWidth = geometry.size.width
            let actualPreviewHeight = min(
                previewHeight,
                previewWidth / max(cameraService.sensorAspectRatio, 0.0001)
            )

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black

                        ExperimentalCameraPreviewView(session: cameraService.session)
                            .frame(width: previewWidth, height: actualPreviewHeight)
                            .background(Color.black)

                        ExperimentalGuidesOverlay(
                            eyeLinePosition: eyeLinePositionBinding,
                            mouthLinePosition: mouthLinePositionBinding,
                            isEditingGuides: $isEditingGuides,
                            isInteractionDisabled: guideInteractionDisabled
                        )
                        .frame(width: previewWidth, height: actualPreviewHeight)
                        .allowsHitTesting(isEditingGuides && !guideInteractionDisabled)

                        if let captureFeedbackStage, !showingCapturePreview {
                            captureStatusOverlay(
                                for: captureFeedbackStage,
                                bottomInset: bottomInset
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .background(Color.black)
                    .contentShape(Rectangle())

                    experimentalControlBar(bottomInset: bottomInset, height: bottomBarHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showingCapturePreview, let pendingCaptureImage {
                    ExperimentalCapturePreviewOverlay(
                        image: pendingCaptureImage,
                        livePhotoImageURL: pendingLivePhotoImageURL,
                        livePhotoVideoURL: pendingLivePhotoVideoURL,
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
            captureFeedbackStage = nil
            if let capture = cameraService.livePhotoCapture {
                pendingCaptureImage = capture.image
                pendingCaptureImageData = capture.imageData
                pendingLivePhotoImageData = capture.imageData
                pendingLivePhotoImageURL = makeTemporaryPreviewImageURL(from: capture.imageData)
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
                pendingLivePhotoImageURL = nil
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
            if !showingCapturePreview {
                captureFeedbackStage = .processingCapture
            }
        }
    }

    @ViewBuilder
    private func experimentalControlBar(bottomInset: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isEditingGuides {
                        Spacer(minLength: 0)
                            .frame(maxWidth: .infinity)
                    } else {
                        HStack {
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(Color.white.opacity(0.08), in: Circle())
                            }
                            .disabled(controlsDisabled)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .leading).combined(with: .opacity))

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
                        .frame(width: 120)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }

                    HStack {
                        Spacer(minLength: 0)

                        if isEditingGuides {
                            HStack(spacing: 10) {
                                Button(action: cancelGuideEditing) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "xmark")
                                            .font(.title3)
                                        Text("Cancel")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(Color.white.opacity(0.08))
                                    )
                                }

                                Button(action: commitGuideEditing) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "checkmark")
                                            .font(.title3)
                                        Text("Done")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(Color.white.opacity(0.18))
                                    )
                                }
                            }
                        } else {
                            Button(action: beginGuideEditing) {
                                VStack(spacing: 4) {
                                    Image(systemName: "eye")
                                        .font(.title3)
                                    Text("Guides")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                            }
                            .disabled(guideInteractionDisabled)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .frame(height: 116)
                .animation(.easeInOut(duration: 0.18), value: isEditingGuides)

                Spacer()
                    .frame(height: bottomInset)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private var eyeLinePositionBinding: Binding<Double> {
        Binding(
            get: { draftEyeLinePosition ?? alignmentGuideStore.eyeLinePosition },
            set: {
                if isEditingGuides {
                    draftEyeLinePosition = $0
                } else {
                    alignmentGuideStore.eyeLinePosition = $0
                }
            }
        )
    }

    private var mouthLinePositionBinding: Binding<Double> {
        Binding(
            get: { draftMouthLinePosition ?? alignmentGuideStore.mouthLinePosition },
            set: {
                if isEditingGuides {
                    draftMouthLinePosition = $0
                } else {
                    alignmentGuideStore.mouthLinePosition = $0
                }
            }
        )
    }

    private func beginGuideEditing() {
        draftEyeLinePosition = alignmentGuideStore.eyeLinePosition
        draftMouthLinePosition = alignmentGuideStore.mouthLinePosition
        isEditingGuides = true
    }

    private func cancelGuideEditing() {
        draftEyeLinePosition = nil
        draftMouthLinePosition = nil
        isEditingGuides = false
    }

    private func commitGuideEditing() {
        if let draftEyeLinePosition {
            alignmentGuideStore.eyeLinePosition = draftEyeLinePosition
        }
        if let draftMouthLinePosition {
            alignmentGuideStore.mouthLinePosition = draftMouthLinePosition
        }
        draftEyeLinePosition = nil
        draftMouthLinePosition = nil
        isEditingGuides = false
    }

    private func capturePhoto() {
        guard !showingCapturePreview else { return }
        isCapturing = true
        #if targetEnvironment(simulator)
        captureFeedbackStage = .processingCapture
        #else
        captureFeedbackStage = .recordingLivePhoto
        #endif
        let captureLocation = locationService.currentLocation
        #if targetEnvironment(simulator)
        cameraService.capturePhoto(withLivePhoto: false, location: captureLocation)
        #else
        cameraService.capturePhoto(withLivePhoto: true, location: captureLocation)
        #endif
    }

    private func retakeCapture() {
        isAnimatingPreviewToGrid = false
        captureFeedbackStage = nil
        pendingCaptureImage = nil
        pendingCaptureImageData = nil
        pendingLivePhotoImageData = nil
        if let pendingLivePhotoImageURL {
            try? FileManager.default.removeItem(at: pendingLivePhotoImageURL)
        }
        pendingLivePhotoImageURL = nil
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

    @ViewBuilder
    private func captureStatusOverlay(for stage: CaptureFeedbackStage, bottomInset: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                Image(systemName: stage.symbolName)
                    .font(.title3)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.subheadline.weight(.semibold))
                    Text(stage.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                ProgressView()
                    .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, bottomInset + 28)
        }
        .transition(.opacity)
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
                    if let pendingLivePhotoImageURL {
                        try? FileManager.default.removeItem(at: pendingLivePhotoImageURL)
                    }
                    pendingLivePhotoImageURL = nil
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

        let clock = ContinuousClock()
        let saveStartedAt = clock.now
        do {
            _ = try await PhotoStorageService.shared.savePhoto(
                image: image,
                imageData: imageData,
                livePhotoImageData: livePhotoImageData,
                livePhotoVideoURL: videoURL,
                location: location,
                context: viewContext
            )
            try? await enforceMinimumSaveDelay(startedAt: saveStartedAt, clock: clock)
        } catch {
            print("Error saving photo: \(error.localizedDescription)")
            try? await enforceMinimumSaveDelay(startedAt: saveStartedAt, clock: clock)
        }
    }

    private func enforceMinimumSaveDelay(startedAt: ContinuousClock.Instant, clock: ContinuousClock) async throws {
        guard
            let rawValue = processInfo.environment["UI_TEST_MIN_SAVE_DELAY"],
            let delaySeconds = Double(rawValue),
            delaySeconds > 0
        else {
            return
        }

        let elapsed = startedAt.duration(to: clock.now)
        let minimum = Duration.seconds(delaySeconds)
        guard elapsed < minimum else { return }
        try await Task.sleep(for: minimum - elapsed)
    }

    private func makeTemporaryPreviewImageURL(from imageData: Data) -> URL? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        do {
            try imageData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}

struct ExperimentalCapturePreviewOverlay: View {
    let image: UIImage
    let livePhotoImageURL: URL?
    let livePhotoVideoURL: URL?
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

                        SnapBackZoomContainer {
                            Group {
                                if let livePhotoImageURL, let livePhotoVideoURL {
                                    LivePhotoContainerView(
                                        imageURL: livePhotoImageURL,
                                        videoURL: livePhotoVideoURL,
                                        fallbackImage: image
                                    )
                                } else {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .aspectRatio(image.size, contentMode: .fit)
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

                        HStack(spacing: 14) {
                        Button(action: onRetake) {
                            Text("Retake")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                        .accessibilityIdentifier("capturePreviewRetakeButton")
                        .disabled(isSaving)

                        Button(action: onDone) {
                            if isSaving {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Saving…")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .accessibilityIdentifier("capturePreviewSavingIndicator")
                            } else {
                                Text("Done")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                            }
                        }
                        .accessibilityIdentifier("capturePreviewDoneButton")
                        .foregroundStyle(.black)
                        .background(Color.white, in: Capsule())
                        .disabled(isSaving)
                    }
                    .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)

                    if isSaving {
                        Text("Uploading the original photo and saving metadata.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                    }
                    .padding(.top, max(geometry.safeAreaInsets.top - 4, 0))
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
        .accessibilityIdentifier("capturePreviewOverlay")
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
    private let centerPosition: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            let eyeY = geometry.size.height * eyeLinePosition
            let mouthY = geometry.size.height * mouthLinePosition
            let horizontalLineWidth = max(geometry.size.width - 36, 0)

            ZStack {
                guideLine(color: .white.opacity(0.28), width: 1.5)
                    .frame(height: geometry.size.height)

                faceLine(
                    y: eyeY,
                    color: .white.opacity(0.85),
                    width: horizontalLineWidth,
                    label: "Eyes"
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEditingGuides, !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                updateGuides(fromEyeLine: normalized)
                            }
                    )

                faceLine(
                    y: mouthY,
                    color: .white.opacity(0.85),
                    width: horizontalLineWidth,
                    label: "Mouth"
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEditingGuides, !isInteractionDisabled else { return }
                                let normalized = value.location.y / max(geometry.size.height, 1)
                                updateGuides(fromMouthLine: normalized)
                            }
                    )

            }
            .padding(.horizontal, 18)
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
        color: Color,
        width: CGFloat,
        label: String
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

            if isEditingGuides {
                HStack(spacing: 6) {
                    Image(systemName: label == "Eyes" ? "eye" : "mouth")
                        .font(.caption2)
                    Text(label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.up.and.down")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                )
                .padding(.leading, 10)
                .offset(y: -22)
            }
        }
        .frame(width: width, alignment: .leading)
        .position(x: width / 2, y: y)
    }

    private func updateGuides(fromEyeLine normalized: Double) {
        let maximumOffset = centerPosition - topMin
        let minimumOffset = minGap / 2
        let offset = min(max(centerPosition - normalized, minimumOffset), maximumOffset)
        applySymmetricOffset(offset)
    }

    private func updateGuides(fromMouthLine normalized: Double) {
        let maximumOffset = centerPosition - topMin
        let minimumOffset = minGap / 2
        let offset = min(max(normalized - centerPosition, minimumOffset), maximumOffset)
        applySymmetricOffset(offset)
    }

    private func applySymmetricOffset(_ offset: Double) {
        eyeLinePosition = centerPosition - offset
        mouthLinePosition = centerPosition + offset
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
