import Photos
import SwiftUI

struct PortraitVideoExportSheet: View {
    let photos: [PortraitVideoExportItem]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("portraitVideoPicturesPerSecond") private var picturesPerSecond = 6
    @AppStorage("portraitVideoQuality") private var selectedQualityRawValue = PortraitVideoExportQuality.best.rawValue
    @AppStorage("portraitVideoIncludesDateBanner") private var includesDateBanner = false
    @AppStorage("portraitVideoIncludesLocationBanner") private var includesLocationBanner = false
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
                summarySection
                videoSection
                dateRangeSection
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(10)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .navigationTitle("Video Creator")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        cancelExport()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .interactiveDismissDisabled(exportTask != nil)
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

    private var summarySection: some View {
        Section {
            HStack(spacing: 10) {
                summaryPill(
                    title: "\(matchingPhotos.count)",
                    subtitle: matchingPhotos.count == 1 ? "Photo" : "Photos",
                    systemImage: "photo.stack"
                )
                summaryPill(
                    title: formattedDuration(Double(matchingPhotos.count) / Double(picturesPerSecond)),
                    subtitle: "Length",
                    systemImage: "timer"
                )
                summaryPill(
                    title: "\(picturesPerSecond)/s",
                    subtitle: "Speed",
                    systemImage: "speedometer"
                )
            }
            .padding(.vertical, 0)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
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

        let duration = Double(count) / Double(picturesPerSecond)
        return "\(count) photo\(count == 1 ? "" : "s") · \(formattedDuration(duration))"
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

    private var bottomActionBar: some View {
        VStack(spacing: 12) {
            if let progress {
                progressView(for: progress)
            }

            if let statusMessage {
                statusView(statusMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !failedPhotos.isEmpty {
                Button {
                    isShowingFailedPhotos = true
                } label: {
                    Label(skippedPhotosButtonTitle, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if exportTask != nil {
                Button(role: .destructive, action: cancelExport) {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if exportedVideoURL == nil {
                Button(action: startExport) {
                    Label("Create Video", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(exportTask != nil || matchingPhotos.isEmpty)
            } else {
                HStack(spacing: 10) {
                    Button(action: saveToPhotos) {
                        saveToPhotosLabel
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSavingToPhotos)

                    Button {
                        isShowingFilesExporter = true
                    } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.25), value: statusMessage)
    }

    @ViewBuilder
    private var saveToPhotosLabel: some View {
        if isSavingToPhotos {
            HStack {
                ProgressView()
                Text("Saving...")
            }
        } else {
            Label("Photos", systemImage: "photo.on.rectangle")
        }
    }

    private func progressView(for progress: PortraitVideoExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progressText(for: progress))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ProgressView(
                value: Double(progress.completedPhotoCount),
                total: Double(max(progress.totalPhotoCount, 1))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusView(_ message: String) -> some View {
        Label(message, systemImage: isStatusSuccess ? "checkmark.circle.fill" : "info.circle")
            .font(.footnote)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        isStatusSuccess ? .green : .secondary
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
                    includesLocationBanner: includesLocationBanner
                ) { newProgress in
                    progress = newProgress
                }

                exportedVideoURL = result.videoURL
                failedPhotos = result.failedPhotos
                progress = nil
                isStatusSuccess = true
                statusMessage = result.failedPhotos.isEmpty
                    ? "Video ready."
                    : "Video ready. \(result.failedPhotos.count) skipped."
            } catch is CancellationError {
                progress = nil
                showStatus("Video creation cancelled.", success: false)
            } catch PortraitVideoExportError.noFramesWritten(let failures) {
                failedPhotos = failures
                progress = nil
                showStatus("No video created. \(failures.count) skipped.", success: false)
            } catch {
                progress = nil
                showStatus("Video creation failed: \(error.localizedDescription)", success: false)
            }

            exportTask = nil
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
