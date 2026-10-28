import SwiftUI
import AVFoundation
import CoreData
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

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

    @State private var storage = PhotoStorageCoordinator.shared
    @StateObject private var cameraService = CameraService()
    @StateObject private var locationService = LocationService()
    @StateObject private var alignmentGuideStore: AlignmentGuideStore
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var timelines = TimelineSelectionStore.shared
    @State private var isUpdatingLivePhotoPreference = false
    @State private var livePhotoPreferenceError: String?
    @State private var isUpdatingCameraPreference = false
    @State private var cameraPreferenceError: String?

    private var preferredCameraPosition: CameraPosition {
        TimelineCameraPreferences.cameraPosition(for: timelineID, in: timelines)
    }

    private var isLivePhotoCaptureEnabled: Bool {
        TimelineCameraPreferences.livePhotosEnabled(for: timelineID, in: timelines)
    }
    @AppStorage(CameraPreferenceKey.hirsModeEnabled) private var isHirsModeEnabled = false

    let gridTargetFrameInGlobal: CGRect?
    let timelineID: UUID

    init(gridTargetFrameInGlobal: CGRect? = nil, timelineID: UUID = TimelineIdentity.defaultID) {
        self.gridTargetFrameInGlobal = gridTargetFrameInGlobal
        self.timelineID = timelineID
        _alignmentGuideStore = StateObject(wrappedValue: AlignmentGuideStore(timelineID: timelineID))
    }

    @State private var isEditingGuides = false
    @State private var isSaving = false
    @State private var saveHaptics = CaptureSaveHaptics()
    @State private var isCameraVisible = false
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""
    @State private var showingCaptureError = false
    @State private var showingCapturePreview = false
    @State private var pendingCaptureImage: UIImage?
    @State private var pendingCaptureImageData: Data?
    @State private var pendingLivePhotoImageData: Data?
    @State private var pendingLivePhotoImageURL: URL?
    @State private var pendingLivePhotoVideoURL: URL?
    @State private var isCapturing = false
    @State private var livePhotoPreferenceAtCapture: Bool?
    @State private var cameraPositionAtCapture: CameraPosition?
    @State private var isAnimatingPreviewToGrid = false
    @State private var previewDismissOffset: CGFloat = 0
    @State private var captureFeedbackStage: CaptureFeedbackStage?
    @State private var draftEyeLinePosition: Double?
    @State private var draftMouthLinePosition: Double?
    @State private var draftGuidesVisible: Bool?
    @State private var didPresentMockCapture = false
    #if DEBUG
    @State private var didInjectSaveFailure = false
    #endif
    private let processInfo = ProcessInfo.processInfo

    private var guideInteractionDisabled: Bool {
        isCapturing || isSaving || showingCapturePreview || captureFeedbackStage != nil
    }

    private var controlsDisabled: Bool {
        guideInteractionDisabled || isEditingGuides || isUpdatingLivePhotoPreference || isUpdatingCameraPreference
            || cameraService.isConfiguringCamera
            || (!usesMockCapture && !cameraService.isReadyForCapture)
    }

    private var usesMockCapture: Bool {
        processInfo.arguments.contains("UI_TEST_MOCK_CAPTURE")
            || processInfo.environment["UI_TEST_MOCK_CAPTURE"] == "1"
    }

    var body: some View {
        GeometryReader { geometry in
            let bottomBarHeight: CGFloat = 116
            let previewHeight = max(geometry.size.height - bottomBarHeight, 0)
            let previewAspectRatio = max(cameraService.sensorAspectRatio, 0.0001)
            // Keep guides aligned with the portrait image when height limits the preview.
            let previewWidth = min(geometry.size.width, previewHeight * previewAspectRatio)
            let actualPreviewHeight = previewWidth / previewAspectRatio

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black

                        ExperimentalCameraPreviewView(session: cameraService.session, position: cameraService.cameraPosition)
                            .frame(width: previewWidth, height: actualPreviewHeight)
                            .background(Color.black)

                        if areGuidesVisible {
                            ExperimentalGuidesOverlay(
                                eyeLinePosition: eyeLinePositionBinding,
                                mouthLinePosition: mouthLinePositionBinding,
                                isEditingGuides: $isEditingGuides,
                                isInteractionDisabled: guideInteractionDisabled
                            )
                            .frame(width: previewWidth, height: actualPreviewHeight)
                            .allowsHitTesting(isEditingGuides && !guideInteractionDisabled)
                        }

                        if let captureFeedbackStage, !showingCapturePreview {
                            captureStatusOverlay(for: captureFeedbackStage)
                        }

                        if shouldShowLivePhotoToggle {
                            VStack {
                                HStack {
                                    cameraSwitchButton
                                    Spacer()
                                    livePhotoToggleButton
                                }
                                .padding(.top, 16)
                                .padding(.horizontal, 16)

                                Spacer()
                            }
                            .frame(width: previewWidth, height: actualPreviewHeight)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .background(Color.black)
                    .contentShape(Rectangle())

                    experimentalControlBar(height: bottomBarHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showingCapturePreview, let pendingCaptureImage {
                    ExperimentalCapturePreviewOverlay(
                        image: pendingCaptureImage,
                        livePhotoImageURL: pendingLivePhotoImageURL,
                        livePhotoVideoURL: pendingLivePhotoVideoURL,
                        isMirrored: isHirsModeEnabled,
                        isSaving: isSaving,
                        savingDetail: storage.isLocalOnly ? "Saving photo on this device." : "Saving photo for iCloud sync.",
                        isAnimatingToGrid: isAnimatingPreviewToGrid,
                        dismissOffset: previewDismissOffset,
                        targetFrameInGlobal: gridTargetFrameInGlobal,
                        onRetake: retakeCapture,
                        onDone: confirmSave,
                        onDismiss: dismissCapturePreview,
                        onDragChanged: updatePreviewDrag,
                        onDragCancelled: cancelPreviewDrag,
                        onFlightStarted: saveHaptics.beginFlight,
                        onLanding: saveHaptics.land,
                        onFlightCompleted: finishSavedCapture
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom)
                    ))
                    .zIndex(2)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard !isEditingGuides else { return }
                        guard value.translation.height > 100 else { return }

                        guard !showingCapturePreview else { return }
                        dismiss()
                    }
            )
        }
        .task(id: cameraSessionRequest) {
            guard !cameraSessionRequest.paused else {
                cameraService.stopSession()
                return
            }
            await timelines.start(in: viewContext)
            guard !Task.isCancelled else { return }
            if usesMockCapture {
                if !didPresentMockCapture {
                    didPresentMockCapture = true
                    presentMockCapturePreview()
                }
                return
            }

            await cameraService.checkAuthorization()
            guard !Task.isCancelled else { return }
            if cameraService.isAuthorized {
                await cameraService.setupCamera(position: cameraSessionRequest.position)
                guard !Task.isCancelled else { return }
                do {
                    try await TimelineCameraPreferences.migrateLegacyPreference(
                        for: timelineID, supported: cameraService.isLivePhotoCaptureSupported,
                        timelines: timelines, context: viewContext)
                } catch { livePhotoPreferenceError = error.localizedDescription }
                guard !Task.isCancelled else { return }
                await cameraService.configureLivePhotoAudio(enabled: isLivePhotoCaptureEnabled)
                guard !Task.isCancelled else { return }
                cameraService.startSession()
            }

            if !usesMockCapture {
                locationService.requestPermission()
            }
        }
        .onAppear { isCameraVisible = true }
        .onDisappear {
            isCameraVisible = false
            saveHaptics.cancel()
            cameraService.stopSession()
            if !isSaving || isAnimatingPreviewToGrid {
                clearPendingCapture()
                isAnimatingPreviewToGrid = false
                isSaving = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveHaptics.cancel() }
        }
        .onChange(of: showingCapturePreview) { _, isShowing in
            if isShowing { saveHaptics.prepare() }
        }
        .interactiveDismissDisabled(isSaving || isCapturing)
        .onChange(of: cameraService.captureCompleted) { _, _ in
            livePhotoPreferenceAtCapture = nil
            cameraPositionAtCapture = nil
            isCapturing = false
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
            if !showingCapturePreview, cameraService.captureErrorMessage == nil {
                captureFeedbackStage = .processingCapture
            }
        }
        .onChange(of: cameraService.captureErrorMessage) { _, message in
            guard message != nil else { return }
            livePhotoPreferenceAtCapture = nil
            cameraPositionAtCapture = nil
            isCapturing = false
            captureFeedbackStage = nil
            showingCaptureError = true
        }
        .alert("Unable to Take Photo", isPresented: $showingCaptureError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cameraService.captureErrorMessage ?? "Please try again.")
        }
        .alert("Unable to Update Live Photos", isPresented: Binding(
            get: { livePhotoPreferenceError != nil },
            set: { if !$0 { livePhotoPreferenceError = nil } }
        )) {
            Button("OK", role: .cancel) { livePhotoPreferenceError = nil }
        } message: {
            Text(livePhotoPreferenceError ?? "Please try again.")
        }
        .alert("Unable to Save Photo", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your capture is still available. Try saving again.\n\n\(saveErrorMessage)")
        }
        .alert("Unable to Switch Camera", isPresented: Binding(
            get: { cameraPreferenceError != nil },
            set: { if !$0 { cameraPreferenceError = nil } }
        )) {
            Button("OK", role: .cancel) { cameraPreferenceError = nil }
        } message: {
            Text(cameraPreferenceError ?? "Please try again.")
        }
    }

    private struct CameraSessionRequest: Equatable {
        let livePhotosEnabled: Bool
        let position: CameraPosition
        let paused: Bool
    }

    private var cameraSessionRequest: CameraSessionRequest {
        CameraSessionRequest(
            // A remote preference change must not reconfigure an exposure in flight.
            livePhotosEnabled: livePhotoPreferenceAtCapture ?? isLivePhotoCaptureEnabled,
            position: cameraPositionAtCapture ?? preferredCameraPosition,
            paused: scenePhase == .background || showingCapturePreview
        )
    }

    private var shouldShowLivePhotoToggle: Bool {
        !isEditingGuides && !showingCapturePreview
    }

    private var shouldCaptureLivePhoto: Bool {
        TimelineCameraPreferences.capturesLivePhoto(preferred: isLivePhotoCaptureEnabled,
                                                   supported: cameraService.isLivePhotoCaptureSupported)
    }

    @ViewBuilder
    private func experimentalControlBar(height: CGFloat) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isEditingGuides {
                        HStack {
                            guideVisibilityButton
                            Spacer(minLength: 0)
                        }
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
                            .accessibilityLabel("Close Camera")
                            .accessibilityIdentifier("experimentalCameraCloseButton")
                            .disabled(guideInteractionDisabled)

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
                                    Image(systemName: areGuidesVisible ? "eye" : "eye.slash")
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
                .frame(maxWidth: 600)
                .frame(height: 116)
                .animation(.easeInOut(duration: 0.18), value: isEditingGuides)

            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private var areGuidesVisible: Bool {
        draftGuidesVisible ?? alignmentGuideStore.isVisible
    }

    private var guideVisibilityButton: some View {
        Button {
            draftGuidesVisible = !areGuidesVisible
        } label: {
            VStack(spacing: 4) {
                Image(systemName: areGuidesVisible ? "eye.slash" : "eye")
                    .font(.title3)
                Text(areGuidesVisible ? "Hide" : "Show")
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
        .accessibilityLabel(areGuidesVisible ? "Hide Guides" : "Show Guides")
        .accessibilityValue(areGuidesVisible ? "Visible" : "Hidden")
        .accessibilityIdentifier("experimentalCameraGuideVisibilityButton")
        .disabled(guideInteractionDisabled)
    }

    private var livePhotoToggleButton: some View {
        Button(action: toggleLivePhotos) {
            Image(systemName: livePhotoToggleSymbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.46), in: Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(shouldCaptureLivePhoto ? 0.44 : 0.16), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if shouldCaptureLivePhoto && cameraService.livePhotoAudioUnavailable {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(3)
                            .background(.black, in: Circle())
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("experimentalCameraLivePhotoToggle")
        .accessibilityLabel(livePhotoToggleAccessibilityLabel)
        .accessibilityValue(livePhotoToggleAccessibilityValue)
        .disabled(guideInteractionDisabled || isUpdatingLivePhotoPreference || isUpdatingCameraPreference
                  || cameraService.isConfiguringCamera || storage.mode.isMigrating
                  || !cameraService.isLivePhotoCaptureSupported)
    }

    private var cameraSwitchButton: some View {
        Button(cameraService.cameraPosition == .front ? "Switch to Back Camera" : "Switch to Front Camera",
               systemImage: "arrow.triangle.2.circlepath.camera", action: switchCamera)
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.46), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.44), lineWidth: 1))
            .buttonStyle(.plain)
            .accessibilityIdentifier("experimentalCameraSwitchCamera")
            .accessibilityValue(cameraService.cameraPosition == .front ? "Front Camera" : "Back Camera")
            .disabled(guideInteractionDisabled || isUpdatingCameraPreference || isUpdatingLivePhotoPreference
                      || cameraService.isConfiguringCamera || storage.mode.isMigrating || !cameraService.canSwitchCamera)
    }

    private func switchCamera() {
        guard !guideInteractionDisabled, !isUpdatingCameraPreference, !isUpdatingLivePhotoPreference,
              !cameraService.isConfiguringCamera, !storage.mode.isMigrating,
              cameraService.canSwitchCamera else { return }
        let position = cameraService.cameraPosition.opposite
        isUpdatingCameraPreference = true
        Task {
            defer { isUpdatingCameraPreference = false }
            do {
                try await timelines.setCameraPosition(position, for: timelineID, in: viewContext)
            } catch { cameraPreferenceError = error.localizedDescription }
        }
    }

    private func toggleLivePhotos() {
        guard cameraService.isLivePhotoCaptureSupported, !guideInteractionDisabled,
              !isUpdatingLivePhotoPreference, !isUpdatingCameraPreference,
              !cameraService.isConfiguringCamera, !storage.mode.isMigrating else { return }
        let enabled = !isLivePhotoCaptureEnabled
        isUpdatingLivePhotoPreference = true
        Task {
            defer { isUpdatingLivePhotoPreference = false }
            do {
                try await TimelineCameraPreferences.setLivePhotosEnabled(enabled, for: timelineID,
                    supported: cameraService.isLivePhotoCaptureSupported, timelines: timelines, context: viewContext)
            } catch { livePhotoPreferenceError = error.localizedDescription }
        }
    }

    private var livePhotoToggleSymbolName: String {
        shouldCaptureLivePhoto ? "livephoto" : "livephoto.slash"
    }

    private var livePhotoToggleAccessibilityLabel: String {
        guard cameraService.isLivePhotoCaptureSupported else {
            return "Live Photos Unavailable"
        }
        return isLivePhotoCaptureEnabled ? "Turn Off Live Photos" : "Turn On Live Photos"
    }

    private var livePhotoToggleAccessibilityValue: String {
        guard cameraService.isLivePhotoCaptureSupported else {
            return "Unavailable"
        }
        if shouldCaptureLivePhoto && cameraService.livePhotoAudioUnavailable {
            return "On, without sound. Enable microphone access in Settings to record sound."
        }
        return isLivePhotoCaptureEnabled ? "On" : "Off"
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
        draftGuidesVisible = alignmentGuideStore.isVisible
        isEditingGuides = true
    }

    private func cancelGuideEditing() {
        draftEyeLinePosition = nil
        draftMouthLinePosition = nil
        draftGuidesVisible = nil
        isEditingGuides = false
    }

    private func commitGuideEditing() {
        if let draftEyeLinePosition {
            alignmentGuideStore.eyeLinePosition = draftEyeLinePosition
        }
        if let draftMouthLinePosition {
            alignmentGuideStore.mouthLinePosition = draftMouthLinePosition
        }
        if let draftGuidesVisible {
            alignmentGuideStore.isVisible = draftGuidesVisible
        }
        draftEyeLinePosition = nil
        draftMouthLinePosition = nil
        draftGuidesVisible = nil
        isEditingGuides = false
    }

    private func capturePhoto() {
        guard !controlsDisabled else { return }

        if usesMockCapture {
            presentMockCapturePreview()
            return
        }

        livePhotoPreferenceAtCapture = isLivePhotoCaptureEnabled
        cameraPositionAtCapture = preferredCameraPosition
        isCapturing = true
        #if targetEnvironment(simulator)
        captureFeedbackStage = .processingCapture
        #else
        captureFeedbackStage = shouldCaptureLivePhoto ? .recordingLivePhoto : .processingCapture
        #endif
        let captureLocation = locationService.currentLocation
        #if targetEnvironment(simulator)
        cameraService.capturePhoto(withLivePhoto: false, location: captureLocation)
        #else
        cameraService.capturePhoto(withLivePhoto: shouldCaptureLivePhoto, location: captureLocation)
        #endif
    }

    private func presentMockCapturePreview() {
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

        pendingCaptureImage = image
        pendingCaptureImageData = image.jpegData(compressionQuality: 0.95)
        pendingLivePhotoImageData = nil
        pendingLivePhotoImageURL = nil
        pendingLivePhotoVideoURL = nil
        isCapturing = false
        captureFeedbackStage = nil
        isAnimatingPreviewToGrid = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showingCapturePreview = true
        }
    }

    private func retakeCapture() {
        guard showingCapturePreview, !isSaving else { return }
        isAnimatingPreviewToGrid = false
        captureFeedbackStage = nil
        resumeCameraForPreviewDismissal()
        withAnimation(.easeOut(duration: 0.32)) {
            showingCapturePreview = false
        } completion: {
            clearPendingCapture()
            previewDismissOffset = 0
        }
    }

    private func clearPendingCapture() {
        livePhotoPreferenceAtCapture = nil
        cameraPositionAtCapture = nil
        pendingCaptureImage = nil
        pendingCaptureImageData = nil
        pendingLivePhotoImageData = nil
        if let pendingLivePhotoImageURL {
            try? FileManager.default.removeItem(at: pendingLivePhotoImageURL)
        }
        if let pendingLivePhotoVideoURL {
            try? FileManager.default.removeItem(at: pendingLivePhotoVideoURL)
        }
        pendingLivePhotoImageURL = nil
        pendingLivePhotoVideoURL = nil
        cameraService.discardCapture()
    }

    private func resumeCameraForPreviewDismissal() {
        guard !usesMockCapture, scenePhase != .background, cameraService.isAuthorized else { return }
        cameraService.startSession()
    }

    private func updatePreviewDrag(_ translation: CGFloat) {
        let offset = max(translation, 0)
        if offset > 0, previewDismissOffset == 0 {
            resumeCameraForPreviewDismissal()
        }
        previewDismissOffset = offset
    }

    private func cancelPreviewDrag() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            previewDismissOffset = 0
        }
        if !usesMockCapture {
            cameraService.stopSession()
        }
    }

    private func dismissCapturePreview() {
        retakeCapture()
    }

    @ViewBuilder
    private func captureStatusOverlay(for stage: CaptureFeedbackStage) -> some View {
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
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    private func confirmSave() {
        guard showingCapturePreview, !isSaving, !isAnimatingPreviewToGrid,
              let image = pendingCaptureImage else { return }

        let imageData = pendingCaptureImageData
        let livePhotoImageData = pendingLivePhotoImageData
        let videoURL = pendingLivePhotoVideoURL
        isSaving = true
        saveHaptics.beginSaving()

        Task {
            do {
                try await savePhoto(
                    image: image,
                    imageData: imageData,
                    livePhotoImageData: livePhotoImageData,
                    videoURL: videoURL
                )
                guard isCameraVisible else {
                    saveHaptics.cancel()
                    clearPendingCapture()
                    isSaving = false
                    return
                }
                saveHaptics.didSave()
                isAnimatingPreviewToGrid = true
            } catch {
                saveHaptics.cancel()
                isSaving = false
                guard isCameraVisible else { clearPendingCapture(); return }
                saveErrorMessage = error.localizedDescription
                showingSaveError = true
            }
        }
    }

    private func finishSavedCapture() {
        guard isCameraVisible, isAnimatingPreviewToGrid else { return }
        clearPendingCapture()
        isAnimatingPreviewToGrid = false
        isSaving = false
        dismiss()
    }

    private func savePhoto(image: UIImage, imageData: Data?, livePhotoImageData: Data?, videoURL: URL?) async throws {
        let location: (latitude: Double, longitude: Double)?
        if let currentLocation = locationService.currentLocation {
            location = (currentLocation.coordinate.latitude, currentLocation.coordinate.longitude)
        } else {
            location = nil
        }

        let clock = ContinuousClock()
        let saveStartedAt = clock.now
        do {
            #if DEBUG
            if usesMockCapture,
               processInfo.environment["UI_TEST_FAIL_FIRST_CAPTURE_SAVE"] == "1",
               !didInjectSaveFailure {
                didInjectSaveFailure = true
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #endif
            _ = try await PhotoStorageService.shared.savePhoto(
                image: image,
                imageData: imageData,
                livePhotoImageData: livePhotoImageData,
                livePhotoVideoURL: videoURL,
                location: location,
                context: viewContext,
                timelineID: timelineID
            )
            try? await enforceMinimumSaveDelay(startedAt: saveStartedAt, clock: clock)
        } catch {
            try? await enforceMinimumSaveDelay(startedAt: saveStartedAt, clock: clock)
            throw error
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
            .appendingPathExtension(temporaryPreviewImageExtension(for: imageData))

        do {
            try imageData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func temporaryPreviewImageExtension(for imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return "heic"
        }

        return UTType(type as String)?.preferredFilenameExtension ?? "heic"
    }
}

struct ExperimentalCapturePreviewOverlay: View {
    let image: UIImage
    let livePhotoImageURL: URL?
    let livePhotoVideoURL: URL?
    let isMirrored: Bool
    let isSaving: Bool
    let savingDetail: String
    let isAnimatingToGrid: Bool
    let dismissOffset: CGFloat
    let targetFrameInGlobal: CGRect?
    let onRetake: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragCancelled: () -> Void
    let onFlightStarted: () -> Void
    let onLanding: () -> Void
    let onFlightCompleted: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewImageFrameInOverlay: CGRect = .zero
    @State private var animatedFrameInOverlay: CGRect = .zero
    @State private var landingScale: CGFloat = 1
    @State private var flightOpacity: Double = 0

    private var previewTitle: String {
        livePhotoImageURL != nil && livePhotoVideoURL != nil
            ? "Live Photo Preview"
            : "Photo Preview"
    }

    var body: some View {
        GeometryReader { geometry in
            let fallbackTargetSize = min(150, max(100, (geometry.size.width - 4) / 3))
            let containerFrameInGlobal = geometry.frame(in: .global)
            let localTargetFrame: CGRect = {
                guard let targetFrameInGlobal,
                      targetFrameInGlobal != .zero else {
                    return CGRect(
                        x: 1,
                        y: 1,
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
                y: 64,
                width: geometry.size.width - 40,
                height: max(geometry.size.width - 40, 1) * 1.25
            )
            let startFrame = previewImageFrameInOverlay == .zero ? fallbackStartFrame : previewImageFrameInOverlay
            let flightFrame = animatedFrameInOverlay == .zero
                ? (reduceMotion ? localTargetFrame : startFrame) : animatedFrameInOverlay

            ZStack(alignment: .topLeading) {
                Color.black
                    .ignoresSafeArea()

                if !isAnimatingToGrid {
                    VStack(spacing: 18) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 46, height: 5)
                            .padding(.top, 14)

                        Text(previewTitle)
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
                            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
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
                        Text(savingDetail)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: flightFrame.width,
                            height: flightFrame.height
                        )
                        .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                        .scaleEffect(landingScale)
                        .opacity(reduceMotion ? flightOpacity : 1)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .position(
                            x: flightFrame.midX,
                            y: flightFrame.midY
                        )
                        .onAppear {
                            onFlightStarted()
                            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.34), completionCriteria: .logicallyComplete) {
                                animatedFrameInOverlay = localTargetFrame
                                flightOpacity = 1
                            } completion: {
                                onLanding()
                                guard !reduceMotion else { onFlightCompleted(); return }
                                withAnimation(.easeOut(duration: 0.06)) {
                                    landingScale = 0.96
                                } completion: {
                                    withAnimation(.easeOut(duration: 0.08)) {
                                        landingScale = 1
                                    } completion: {
                                        onFlightCompleted()
                                    }
                                }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capturePreviewOverlay")
        .accessibilityValue(isMirrored ? "Mirrored" : "Original")
        .offset(y: dismissOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !isSaving, !isAnimatingToGrid else { return }
                    onDragChanged(value.translation.height)
                }
                .onEnded { value in
                    guard !isSaving, !isAnimatingToGrid else { return }
                    if value.translation.height > 100 {
                        onDismiss()
                    } else {
                        onDragCancelled()
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
    let position: CameraPosition

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect

        configureConnection(view.previewLayer.connection)

        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session

        configureConnection(uiView.previewLayer.connection)
    }

    private func configureConnection(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
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
