import SwiftUI

struct ExperimentalCapturePreviewOverlay: View {
    static let gridRevealAnimation = Animation.easeInOut(duration: 0.36)
    private static let flightAnimation = Animation.spring(duration: 0.62, bounce: 0.28)

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
    let onGridRevealed: () -> Void
    let onFlightStarted: () -> Void
    let onLanding: () -> Void
    let onFlightCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewImageFrame: CGRect = .zero
    @State private var flightFrame: CGRect?
    @State private var hasRevealedGrid = false
    @State private var hasFinishedGridReveal = false
    @State private var isReadyToFly = false
    @State private var hasStartedFlight = false
    @State private var flightCornerRadius: CGFloat = 24
    @State private var flightOpacity = 1.0

    private var previewTitle: String {
        livePhotoImageURL != nil && livePhotoVideoURL != nil
            ? "Live Photo Preview" : "Photo Preview"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(hasRevealedGrid ? 0 : 1)
                    .ignoresSafeArea()

                // Keep the layout mounted while its image hands off to the flight layer.
                VStack(spacing: 18) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(width: 46, height: 5)
                        .padding(.top, 14)
                        .opacity(hasRevealedGrid ? 0 : 1)
                        .accessibilityHidden(true)

                    Text(previewTitle)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .foregroundStyle(.white.opacity(0.92))
                        .opacity(hasRevealedGrid ? 0 : 1)

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
                    .clipShape(.rect(cornerRadius: 24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PreviewImageFramePreferenceKey.self,
                                value: proxy.frame(in: .named("capturePreviewOverlay"))
                            )
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(previewTitle)
                    .accessibilityAddTraits(.isImage)
                    .padding(.horizontal, 20)
                    .opacity(isAnimatingToGrid ? 0 : 1)

                    HStack(spacing: 14) {
                        Button(action: onRetake) {
                            Text("Retake")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                        .accessibilityIdentifier("capturePreviewRetakeButton")
                        .disabled(isSaving)

                        Button(action: onDone) {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.black)
                                        .fixedSize()
                                        .accessibilityIdentifier("capturePreviewSavingIndicator")
                                }
                                Text(isSaving ? "Saving…" : "Done")
                            }
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 15)
                        }
                        .accessibilityIdentifier("capturePreviewDoneButton")
                        .foregroundStyle(.black)
                        .background(.white, in: Capsule())
                        .disabled(isSaving)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .opacity(hasRevealedGrid ? 0 : 1)

                    Text(savingDetail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .opacity(isSaving && !hasRevealedGrid ? 1 : 0)
                        .accessibilityHidden(!isSaving || hasRevealedGrid)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(!isAnimatingToGrid)
                .accessibilityHidden(isAnimatingToGrid)

                if isAnimatingToGrid, let flightFrame {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: flightFrame.width, height: flightFrame.height)
                        .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                        .clipShape(.rect(cornerRadius: flightCornerRadius))
                        .shadow(color: .black.opacity(hasStartedFlight ? 0 : 0.3), radius: 20, y: 10)
                        .opacity(flightOpacity)
                        .position(x: flightFrame.midX, y: flightFrame.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: "capturePreviewOverlay")
            .onPreferenceChange(PreviewImageFramePreferenceKey.self) { frame in
                guard !isAnimatingToGrid, frame.width > 0, frame.height > 0 else { return }
                previewImageFrame = frame
            }
            .onChange(of: isAnimatingToGrid) { _, isReturning in
                guard isReturning else { return }
                revealGrid(in: geometry)
            }
            .onChange(of: targetFrameInGlobal) { _, _ in
                flyToGrid(in: geometry.frame(in: .global))
            }
            .task(id: hasFinishedGridReveal && isAnimatingToGrid) {
                await pauseBeforeFlight(in: geometry.frame(in: .global))
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

    private func revealGrid(in geometry: GeometryProxy) {
        flightFrame = previewImageFrame == .zero
            ? PhotoDetailDismissalGeometry.draggedFrame(
                imageSize: image.size, viewportSize: geometry.size,
                translation: .zero, reduceMotion: true
            )
            : previewImageFrame
        withAnimation(Self.gridRevealAnimation, completionCriteria: .logicallyComplete) {
            hasRevealedGrid = true
        } completion: {
            hasFinishedGridReveal = true
        }
    }

    private func pauseBeforeFlight(in viewport: CGRect) async {
        guard hasFinishedGridReveal, isAnimatingToGrid else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled, isAnimatingToGrid else { return }
        isReadyToFly = true
        onGridRevealed()
        flyToGrid(in: viewport)
    }

    private func flyToGrid(in viewport: CGRect) {
        guard isReadyToFly, !hasStartedFlight, let targetFrameInGlobal else { return }
        let canFly = !reduceMotion && targetFrameInGlobal.width > 0 && targetFrameInGlobal.height > 0
        onFlightStarted()
        withAnimation(canFly ? Self.flightAnimation : .easeOut(duration: 0.14), completionCriteria: .removed) {
            hasStartedFlight = true
            if canFly {
                flightFrame = targetFrameInGlobal.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                flightCornerRadius = 0
            } else {
                flightOpacity = 0
            }
        } completion: {
            onLanding()
            onFlightCompleted()
        }
    }

    private struct PreviewImageFramePreferenceKey: PreferenceKey {
        static var defaultValue: CGRect = .zero

        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }
}
