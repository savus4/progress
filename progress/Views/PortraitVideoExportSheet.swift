import Photos
import SwiftUI

struct PortraitVideoExportSheet: View {
    let photos: [PortraitVideoExportItem]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("portraitVideoPicturesPerSecond") private var picturesPerSecond = 6
    @AppStorage("portraitVideoQuality") private var selectedQualityRawValue = PortraitVideoExportQuality.best.rawValue
    @AppStorage("portraitVideoIncludesDateBanner") private var includesDateBanner = false
    @AppStorage("portraitVideoIncludesLocationBanner") private var includesLocationBanner = false
    @AppStorage("portraitVideoIncludesHeartedLivePhotoVideos") private var includesHeartedLivePhotoVideos = false
    @State private var usesAllPhotos = true
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var progress: PortraitVideoExportProgress?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedVideoURL: URL?
    @State private var failedPhotos: [PortraitVideoExportFailedPhoto] = []
    @State private var isShowingFilesExporter = false
    @State private var isShowingFailedPhotos = false
    @State private var isSavingToPhotos = false
    @State private var statusMessage: String?
    @State private var isStatusSuccess = false
    @State private var statusClearTask: Task<Void, Never>?
    @State private var exportStartedAt: Date?
    @State private var smoothedRemainingSeconds: TimeInterval?
    @State private var isShowingDiscardUnsavedExportAlert = false

    private let calendar = Calendar.current
    private let availableDateRange: ClosedRange<Date>

    init(photos: [PortraitVideoExportItem]) {
        self.photos = photos

        let calendar = Calendar.current
        let dates = photos.map(\.captureDate)
        let minimumDate = dates.min() ?? Date()
        let maximumDate = dates.max() ?? minimumDate
        let lowerBound = calendar.startOfDay(for: minimumDate)
        let upperBound = calendar.endOfDay(for: maximumDate)

        availableDateRange = lowerBound...upperBound
        _startDate = State(initialValue: lowerBound)
        _endDate = State(initialValue: calendar.startOfDay(for: maximumDate))
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                dateRangeSection
            }
            .contentMargins(.top, 110, for: .scrollContent)
            .listSectionSpacing(10)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) {
                floatingSummaryStats
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .navigationTitle("Video Creator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        requestDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(exportTask == nil ? .primary : .tertiary)
                    }
                    .accessibilityLabel("Close")
                    .disabled(exportTask != nil)
                }
            }
            .interactiveDismissDisabled(exportTask != nil || hasUnsavedExportedVideo)
            .alert("Discard Unsaved Video?", isPresented: $isShowingDiscardUnsavedExportAlert) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard Video", role: .destructive) {
                    cleanupExportedVideo()
                    dismiss()
                }
            } message: {
                Text("This video has not been saved. Closing Video Creator will delete it.")
            }
            .onChange(of: startDate) { _, newValue in
                if newValue > endDate {
                    endDate = newValue
                }
            }
            .onChange(of: endDate) { _, newValue in
                if newValue < startDate {
                    startDate = newValue
                }
            }
            .onDisappear {
                if !isShowingFilesExporter {
                    cleanupExportedVideo()
                }
            }
            .sheet(isPresented: $isShowingFilesExporter, onDismiss: {
                cleanupExportedVideo()
                progress = nil
            }) {
                if let exportedVideoURL {
                    ExportDocumentPicker(urls: [exportedVideoURL]) { didExport in
                        if didExport {
                            showStatus("Saved to Files.", success: true, autoDismiss: true)
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingFailedPhotos) {
                PortraitVideoExportFailuresView(failures: failedPhotos)
            }
            .onAppear {
                picturesPerSecond = clampedPicturesPerSecond
                selectedQualityRawValue = selectedQuality.rawValue
            }
        }
    }

    private var floatingSummaryStats: some View {
        HStack(spacing: 10) {
            summaryPill(
                title: "\(matchingPhotos.count)",
                subtitle: matchingPhotos.count == 1 ? "Photo" : "Photos",
                systemImage: "photo.stack"
            )
            summaryPill(
                title: formattedDuration(estimatedVideoDuration),
                subtitle: "Length",
                systemImage: "timer"
            )
            summaryPill(
                title: "\(picturesPerSecond)/s",
                subtitle: "Speed",
                systemImage: "speedometer"
            )
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var videoSection: some View {
        Section("Video") {
            Stepper(
                picturesPerSecondTitle,
                value: $picturesPerSecond,
                in: 1...60
            )

            Slider(
                value: Binding(
                    get: { Double(picturesPerSecond) },
                    set: { picturesPerSecond = Int($0.rounded()) }
                ),
                in: 1...60,
                step: 1
            )
            .accessibilityLabel("Pictures per second")

            Toggle(isOn: $includesDateBanner) {
                Label("Show Date Banner", systemImage: "calendar")
            }

            Toggle(isOn: $includesLocationBanner) {
                Label("Show Location Banner", systemImage: "location")
            }

            Toggle(isOn: $includesHeartedLivePhotoVideos) {
                Label("Use Favorite Live Motion", systemImage: "heart.fill")
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Quality", selection: selectedQualityBinding) {
                    ForEach(PortraitVideoExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedQuality.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .disabled(exportTask != nil)
    }

    private var dateRangeSection: some View {
        Section("Photos") {
            Toggle(isOn: $usesAllPhotos) {
                Label("All Photos", systemImage: "photo.stack")
            }

            if !usesAllPhotos {
                DatePicker(
                    "From",
                    selection: $startDate,
                    in: availableDateRange,
                    displayedComponents: [.date]
                )
                DatePicker(
                    "To",
                    selection: $endDate,
                    in: availableDateRange,
                    displayedComponents: [.date]
                )
            }

            LabeledContent("Selected", value: dateRangeSummary)
        }
        .disabled(exportTask != nil)
    }

    private var matchingPhotos: [PortraitVideoExportItem] {
        guard !usesAllPhotos else {
            return photos
        }

        let lowerBound = calendar.startOfDay(for: startDate)
        let upperBound = calendar.endOfDay(for: endDate)

        return photos.filter { photo in
            photo.captureDate >= lowerBound && photo.captureDate <= upperBound
        }
    }

    private var videoSummary: String {
        let count = matchingPhotos.count
        guard count > 0 else {
            return "No photos in range."
        }

        return "\(count) photo\(count == 1 ? "" : "s") · \(formattedDuration(estimatedVideoDuration))"
    }

    private var dateRangeSummary: String {
        guard !matchingPhotos.isEmpty else {
            return "No photos"
        }

        return videoSummary
    }

    private var picturesPerSecondTitle: String {
        "\(picturesPerSecond) picture\(picturesPerSecond == 1 ? "" : "s") per second"
    }

    private var clampedPicturesPerSecond: Int {
        min(max(picturesPerSecond, 1), 60)
    }

    private var heartedLivePhotoVideoCount: Int {
        guard includesHeartedLivePhotoVideos else { return 0 }
        return matchingPhotos.filter(\.hasHeartedLivePhotoVideo).count
    }

    private var estimatedVideoDuration: TimeInterval {
        let stillPhotoCount = matchingPhotos.count - heartedLivePhotoVideoCount
        return Double(stillPhotoCount) / Double(clampedPicturesPerSecond) +
            Double(heartedLivePhotoVideoCount) * Self.estimatedLivePhotoVideoDuration
    }

    private static let estimatedLivePhotoVideoDuration: TimeInterval = 3.0

    private var selectedQuality: PortraitVideoExportQuality {
        get {
            PortraitVideoExportQuality(rawValue: selectedQualityRawValue) ?? .best
        }
        nonmutating set {
            selectedQualityRawValue = newValue.rawValue
        }
    }

    private var selectedQualityBinding: Binding<PortraitVideoExportQuality> {
        Binding(
            get: { selectedQuality },
            set: { selectedQuality = $0 }
        )
    }

    private var hasUnsavedExportedVideo: Bool {
        exportedVideoURL != nil && !isSavingToPhotos
    }

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            if let progress {
                progressView(for: progress)
            }

            if let statusMessage {
                statusView(statusMessage)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if !failedPhotos.isEmpty, exportTask == nil {
                Button {
                    isShowingFailedPhotos = true
                } label: {
                    Label(skippedPhotosButtonTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(floatingOverlayButtonStyle)
                .foregroundStyle(.orange)
            }

            if exportTask != nil {
                Button(role: .destructive, action: cancelExport) {
                    Label("Cancel Export", systemImage: "xmark.circle.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(floatingOverlayButtonStyle)
                .foregroundStyle(.red)
            } else if exportedVideoURL == nil {
                Button(action: startExport) {
                    Label("Create Video", systemImage: "film.stack.fill")
                        .font(.headline.weight(.semibold))
                        .padding(.horizontal, 24)
                        .frame(minWidth: 220)
                        .frame(height: 56)
                }
                .buttonStyle(floatingOverlayButtonStyle)
                .disabled(exportTask != nil || matchingPhotos.isEmpty)
            } else {
                unsavedVideoReadyView

                HStack(spacing: 10) {
                    Button(action: saveToPhotos) {
                        saveToPhotosLabel
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(floatingOverlayButtonStyle)
                    .disabled(isSavingToPhotos)

                    Button {
                        isShowingFilesExporter = true
                    } label: {
                        Label("Save to Files", systemImage: "folder.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(floatingOverlayButtonStyle)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: exportTask != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: exportedVideoURL != nil)
        .animation(.easeInOut(duration: 0.25), value: statusMessage)
    }

    private var unsavedVideoReadyView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Video Ready")
                    .font(.headline.weight(.semibold))

                Text(videoReadyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .floatingOverlayGlass(cornerRadius: 24)
    }

    private var videoReadyDescription: String {
        if failedPhotos.isEmpty {
            return "Save it before closing. Unsaved export will be deleted."
        }

        let photoText = failedPhotos.count == 1 ? "photo was" : "photos were"
        return "Save it before closing. \(failedPhotos.count) \(photoText) skipped."
    }

    @ViewBuilder
    private var saveToPhotosLabel: some View {
        if isSavingToPhotos {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving...")
            }
            .font(.headline.weight(.semibold))
        } else {
            Label("Save to Photos", systemImage: "photo.on.rectangle.fill")
                .font(.headline.weight(.semibold))
        }
    }

    private func progressView(for progress: PortraitVideoExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(progressText(for: progress))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if let remainingText = progressTimeRemainingText(for: progress) {
                    Text(remainingText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ProgressView(
                value: Double(progress.completedPhotoCount),
                total: Double(max(progress.totalPhotoCount, 1))
            )
            .tint(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingOverlayGlass(cornerRadius: 24)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.96).combined(with: .opacity)
        ))
    }

    private func statusView(_ message: String) -> some View {
        Label(message, systemImage: isStatusSuccess ? "checkmark.circle.fill" : "info.circle")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(statusColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .floatingOverlayGlass(cornerRadius: 22)
    }

    private var statusColor: Color {
        isStatusSuccess ? .green : .secondary
    }

    private var floatingOverlayButtonStyle: some PrimitiveButtonStyle {
        if #available(iOS 26.0, *) {
            return .glass(.regular.interactive())
        } else {
            return .plain
        }
    }

    private func progressTimeRemainingText(for progress: PortraitVideoExportProgress) -> String? {
        guard progress.phase != .preparing else { return nil }
        guard progress.phase != .finishing else { return "<1 min left" }
        guard let smoothedRemainingSeconds else { return nil }

        if smoothedRemainingSeconds < 60 {
            return "<1 min left"
        }

        let minutes = max(1, Int((smoothedRemainingSeconds / 60).rounded(.up)))
        return "~\(minutes) min left"
    }

    private func summaryPill(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
        }
    }

    private func startExport() {
        guard exportTask == nil else { return }

        let selectedPhotos = matchingPhotos
        guard !selectedPhotos.isEmpty else {
            showStatus(PortraitVideoExportError.noPhotos.localizedDescription, success: false)
            return
        }

        cleanupExportedVideo()
        exportedVideoURL = nil
        failedPhotos = []
        exportStartedAt = Date()
        smoothedRemainingSeconds = nil
        clearStatus()
        progress = PortraitVideoExportProgress(
            completedPhotoCount: 0,
            totalPhotoCount: selectedPhotos.count,
            phase: .preparing
        )

        exportTask = Task { @MainActor in
            do {
                let result = try await PortraitVideoExportService.shared.createVideo(
                    from: selectedPhotos,
                    picturesPerSecond: picturesPerSecond,
                    quality: selectedQuality,
                    includesDateBanner: includesDateBanner,
                    includesLocationBanner: includesLocationBanner,
                    includesHeartedLivePhotoVideo: includesHeartedLivePhotoVideos
                ) { newProgress in
                    updateProgress(newProgress)
                }

                exportedVideoURL = result.videoURL
                failedPhotos = result.failedPhotos
                progress = nil
                smoothedRemainingSeconds = nil
                clearStatus()
            } catch is CancellationError {
                progress = nil
                smoothedRemainingSeconds = nil
                showStatus("Video creation cancelled.", success: false)
            } catch PortraitVideoExportError.noFramesWritten(let failures) {
                failedPhotos = failures
                progress = nil
                smoothedRemainingSeconds = nil
                showStatus("No video created. \(failures.count) skipped.", success: false)
            } catch {
                progress = nil
                smoothedRemainingSeconds = nil
                showStatus("Video creation failed: \(error.localizedDescription)", success: false)
            }

            exportTask = nil
        }
    }

    private func updateProgress(_ newProgress: PortraitVideoExportProgress) {
        progress = newProgress
        updateRemainingTimeEstimate(for: newProgress)
    }

    private func updateRemainingTimeEstimate(for progress: PortraitVideoExportProgress) {
        guard progress.phase == .loading || progress.phase == .writing else {
            if progress.phase == .preparing {
                smoothedRemainingSeconds = nil
            }
            return
        }

        guard progress.completedPhotoCount >= 3,
              progress.completedPhotoCount < progress.totalPhotoCount,
              let exportStartedAt else {
            smoothedRemainingSeconds = nil
            return
        }

        let elapsedSeconds = Date().timeIntervalSince(exportStartedAt)
        guard elapsedSeconds >= 1 else {
            smoothedRemainingSeconds = nil
            return
        }

        let completedWork = max(progress.completedWorkUnitCount, 0.1)
        let remainingWork = max(progress.totalWorkUnitCount - progress.completedWorkUnitCount, 0)
        let rawRemainingSeconds = elapsedSeconds / completedWork * remainingWork

        if let previous = smoothedRemainingSeconds {
            smoothedRemainingSeconds = previous * 0.85 + rawRemainingSeconds * 0.15
        } else {
            smoothedRemainingSeconds = rawRemainingSeconds
        }
    }

    private func requestDismiss() {
        if exportTask != nil {
            cancelExport()
            dismiss()
            return
        }

        if hasUnsavedExportedVideo {
            isShowingDiscardUnsavedExportAlert = true
        } else {
            dismiss()
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        if exportTask != nil {
            showStatus("Cancelling...", success: false)
        }
    }

    private func saveToPhotos() {
        guard let exportedVideoURL, !isSavingToPhotos else { return }

        isSavingToPhotos = true
        clearStatus()

        Task { @MainActor in
            defer {
                isSavingToPhotos = false
            }

            do {
                let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                    throw PortraitVideoSaveError.photoLibraryAccessDenied
                }

                try await saveVideoToPhotoLibrary(exportedVideoURL)
                cleanupExportedVideo()
                progress = nil
                showStatus("Saved to Photos.", success: true, autoDismiss: true)
            } catch let error as PortraitVideoSaveError {
                showStatus(error.localizedDescription, success: false)
            } catch {
                showStatus("Unable to save video to Photos.", success: false)
            }
        }
    }

    private func showStatus(_ message: String, success: Bool, autoDismiss: Bool = false) {
        statusClearTask?.cancel()

        withAnimation(.easeInOut(duration: 0.25)) {
            isStatusSuccess = success
            statusMessage = message
        }

        guard autoDismiss else { return }

        statusClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, statusMessage == message else { return }
            clearStatus()
        }
    }

    private func clearStatus() {
        statusClearTask?.cancel()
        statusClearTask = nil

        withAnimation(.easeInOut(duration: 0.25)) {
            statusMessage = nil
            isStatusSuccess = false
        }
    }

    private func cleanupExportedVideo() {
        guard let exportedVideoURL else { return }
        try? FileManager.default.removeItem(at: exportedVideoURL)
        self.exportedVideoURL = nil
    }

    private func saveVideoToPhotoLibrary(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PortraitVideoSaveError.saveFailed)
                }
            }
        }
    }

    private func progressText(for progress: PortraitVideoExportProgress) -> String {
        let countText = "\(progress.completedPhotoCount) of \(progress.totalPhotoCount)"

        switch progress.phase {
        case .preparing:
            return "Preparing video..."
        case .loading:
            return "Loading photos \(countText)"
        case .writing:
            return "Loading photos \(countText)"
        case .finishing:
            return "Finishing video..."
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let roundedSeconds = Int(duration.rounded(.up))
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(seconds)s"
    }

    private var skippedPhotosButtonTitle: String {
        "\(failedPhotos.count) skipped photo\(failedPhotos.count == 1 ? "" : "s")"
    }
}

private struct PortraitVideoExportFailuresView: View {
    let failures: [PortraitVideoExportFailedPhoto]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(failures) { failure in
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.captureDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.headline)

                    if let assetName = failure.assetName {
                        Text(assetName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(failure.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Skipped Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        self.date(
            byAdding: DateComponents(day: 1, second: -1),
            to: startOfDay(for: date)
        ) ?? date
    }
}

private extension View {
    func floatingOverlayGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
    }
}

private enum PortraitVideoSaveError: LocalizedError {
    case photoLibraryAccessDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .photoLibraryAccessDenied:
            return "Allow Photos access to save videos to your library."
        case .saveFailed:
            return "The video could not be saved to Photos."
        }
    }
}
