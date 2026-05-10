import Photos
import SwiftUI

struct PortraitVideoExportSheet: View {
    let photos: [PortraitVideoExportItem]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("portraitVideoPicturesPerSecond") private var picturesPerSecond = 6
    @AppStorage("portraitVideoQuality") private var selectedQualityRawValue = PortraitVideoExportQuality.balanced.rawValue
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var includesDateBanner = false
    @State private var progress: PortraitVideoExportProgress?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedVideoURL: URL?
    @State private var isShowingFilesExporter = false
    @State private var isSavingToPhotos = false
    @State private var statusMessage: String?
    @State private var isStatusSuccess = false

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
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .navigationTitle("Portrait Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        cancelExport()
                        dismiss()
                    }
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
                statusMessage = nil
                isStatusSuccess = false
            }) {
                if let exportedVideoURL {
                    ExportDocumentPicker(urls: [exportedVideoURL])
                }
            }
            .onAppear {
                picturesPerSecond = clampedPicturesPerSecond
            }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Label("Portrait Video", systemImage: "film.stack")
                    .font(.title2.weight(.semibold))

                HStack(spacing: 12) {
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
            }
            .padding(.vertical, 4)
        }
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

            LabeledContent("Format", value: "2:3 portrait HEVC MP4")
            LabeledContent("Resolution", value: "1080 x 1620")
        }
        .disabled(exportTask != nil)
    }

    private var dateRangeSection: some View {
        Section("Date Range") {
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
            LabeledContent("Selected", value: dateRangeSummary)
        }
        .disabled(exportTask != nil)
    }

    private var matchingPhotos: [PortraitVideoExportItem] {
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
            PortraitVideoExportQuality(rawValue: selectedQualityRawValue) ?? .balanced
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
                    Label("Create Portrait Video", systemImage: "film.stack")
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
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func startExport() {
        guard exportTask == nil else { return }

        let selectedPhotos = matchingPhotos
        guard !selectedPhotos.isEmpty else {
            statusMessage = PortraitVideoExportError.noPhotos.localizedDescription
            return
        }

        cleanupExportedVideo()
        exportedVideoURL = nil
        statusMessage = nil
        isStatusSuccess = false
        progress = PortraitVideoExportProgress(
            completedPhotoCount: 0,
            totalPhotoCount: selectedPhotos.count,
            phase: .preparing
        )

        exportTask = Task { @MainActor in
            do {
                let videoURL = try await PortraitVideoExportService.shared.createVideo(
                    from: selectedPhotos,
                    picturesPerSecond: picturesPerSecond,
                    quality: selectedQuality,
                    includesDateBanner: includesDateBanner
                ) { newProgress in
                    progress = newProgress
                }

                exportedVideoURL = videoURL
                progress = nil
                isStatusSuccess = true
                statusMessage = "Video ready."
            } catch is CancellationError {
                progress = nil
                isStatusSuccess = false
                statusMessage = "Video creation cancelled."
            } catch {
                progress = nil
                isStatusSuccess = false
                statusMessage = "Video creation failed: \(error.localizedDescription)"
            }

            exportTask = nil
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        if exportTask != nil {
            isStatusSuccess = false
            statusMessage = "Cancelling..."
        }
    }

    private func saveToPhotos() {
        guard let exportedVideoURL, !isSavingToPhotos else { return }

        isSavingToPhotos = true
        statusMessage = nil
        isStatusSuccess = false

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
                isStatusSuccess = true
                statusMessage = "Saved to Photos."
            } catch let error as PortraitVideoSaveError {
                isStatusSuccess = false
                statusMessage = error.localizedDescription
            } catch {
                isStatusSuccess = false
                statusMessage = "Unable to save video to Photos."
            }
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
            return "Writing frames \(countText)"
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
