import AVFoundation
import CoreData
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

nonisolated struct PortraitVideoExportProgress: Equatable {
    enum Phase: Equatable {
        case preparing
        case loading
        case writing
        case finishing
    }

    let completedPhotoCount: Int
    let totalPhotoCount: Int
    let phase: Phase
    let completedWorkUnitCount: Double
    let totalWorkUnitCount: Double

    init(
        completedPhotoCount: Int,
        totalPhotoCount: Int,
        phase: Phase,
        completedWorkUnitCount: Double? = nil,
        totalWorkUnitCount: Double? = nil
    ) {
        self.completedPhotoCount = completedPhotoCount
        self.totalPhotoCount = totalPhotoCount
        self.phase = phase
        self.completedWorkUnitCount = completedWorkUnitCount ?? Double(completedPhotoCount)
        self.totalWorkUnitCount = totalWorkUnitCount ?? Double(totalPhotoCount)
    }
}

nonisolated struct PortraitVideoExportFailedPhoto: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let captureDate: Date
    let assetName: String?
    let reason: String

    init(photo: PortraitVideoExportItem, reason: String) {
        id = photo.objectID.uriRepresentation().absoluteString
        captureDate = photo.captureDate
        assetName = photo.fullImageAssetName
        self.reason = reason
    }
}

nonisolated struct PortraitVideoExportResult: Sendable {
    let videoURL: URL
    let failedPhotos: [PortraitVideoExportFailedPhoto]
}

nonisolated struct PortraitVideoExportConfiguration: Equatable, Codable, Sendable {
    let picturesPerSecond: Int
    let quality: PortraitVideoExportQuality
    let includesDateBanner: Bool
    let includesLocationBanner: Bool
    let includesFavoriteLivePhotoVideo: Bool
    let holdsHeartedPhotos: Bool
    let usesAllPhotos: Bool
    let startDate: Date
    let endDate: Date
}

nonisolated struct PortraitVideoExportPausedSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let configuration: PortraitVideoExportConfiguration
    let photoIDs: [String]
    let completedPhotoCount: Int
    let segmentFileNames: [String]
    let failedPhotos: [PortraitVideoExportFailedPhoto]

    var totalPhotoCount: Int {
        photoIDs.count
    }
}

nonisolated enum PortraitVideoExportResponse: Sendable {
    case completed(PortraitVideoExportResult)
    case paused(PortraitVideoExportPausedSession)
}

nonisolated private struct PortraitVideoSegmentWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let fileURL: URL
    let fileName: String
}

nonisolated private struct PortraitVideoExportWorkEstimate: Sendable {
    enum AssetReadKind: Sendable {
        case local
        case remote
    }

    private static let defaultRemoteWorkUnit = 4.0
    private static let storageKey = "portraitVideoRemotePhotoWorkUnit"
    private static let minimumRemoteWorkUnit = 1.25
    private static let maximumRemoteWorkUnit = 20.0

    let photoReadKinds: [AssetReadKind]
    private(set) var remoteWorkUnit: Double
    private var localDurationTotal: TimeInterval = 0
    private var localDurationCount = 0
    private var remoteDurationTotal: TimeInterval = 0
    private var remoteDurationCount = 0

    init(photoReadKinds: [AssetReadKind]) {
        self.photoReadKinds = photoReadKinds
        remoteWorkUnit = Self.storedRemoteWorkUnit()
    }

    var totalWorkUnitCount: Double {
        photoReadKinds.reduce(0) { partialResult, kind in
            partialResult + workUnit(for: kind)
        }
    }

    func completedWorkUnitCount(before index: Int) -> Double {
        let endIndex = min(max(index, 0), photoReadKinds.count)
        return photoReadKinds.prefix(endIndex).reduce(0) { partialResult, kind in
            partialResult + workUnit(for: kind)
        }
    }

    func completedWorkUnitCount(through index: Int) -> Double {
        completedWorkUnitCount(before: index + 1)
    }

    mutating func recordPhotoDuration(at index: Int, duration: TimeInterval) {
        guard photoReadKinds.indices.contains(index), duration > 0 else { return }

        switch photoReadKinds[index] {
        case .local:
            localDurationTotal += duration
            localDurationCount += 1
        case .remote:
            remoteDurationTotal += duration
            remoteDurationCount += 1
        }

        updateRemoteWorkUnitFromObservations()
    }

    func saveCalibration() {
        guard localDurationCount > 0, remoteDurationCount > 0 else { return }
        Self.storeRemoteWorkUnit(remoteWorkUnit)
    }

    private func workUnit(for kind: AssetReadKind) -> Double {
        switch kind {
        case .local:
            return 1
        case .remote:
            return remoteWorkUnit
        }
    }

    private mutating func updateRemoteWorkUnitFromObservations() {
        guard localDurationCount > 0, remoteDurationCount > 0 else { return }

        let localAverage = max(localDurationTotal / Double(localDurationCount), 0.05)
        let remoteAverage = max(remoteDurationTotal / Double(remoteDurationCount), 0.05)
        let observedRemoteWorkUnit = Self.clampedRemoteWorkUnit(remoteAverage / localAverage)
        remoteWorkUnit = Self.clampedRemoteWorkUnit(remoteWorkUnit * 0.8 + observedRemoteWorkUnit * 0.2)
    }

    private static func storedRemoteWorkUnit() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: storageKey)
        guard storedValue > 0 else {
            return defaultRemoteWorkUnit
        }

        return clampedRemoteWorkUnit(storedValue)
    }

    private static func storeRemoteWorkUnit(_ remoteWorkUnit: Double) {
        UserDefaults.standard.set(clampedRemoteWorkUnit(remoteWorkUnit), forKey: storageKey)
    }

    private static func clampedRemoteWorkUnit(_ remoteWorkUnit: Double) -> Double {
        min(max(remoteWorkUnit, minimumRemoteWorkUnit), maximumRemoteWorkUnit)
    }
}

nonisolated private struct PortraitVideoBannerText: Sendable {
    let primary: String
    let secondary: String?

    var hasSecondary: Bool {
        secondary != nil
    }
}

nonisolated enum PortraitVideoExportError: LocalizedError {
    case noPhotos
    case noImageAsset
    case cannotCreatePixelBuffer
    case cannotCreateImageContext
    case cannotReadImage
    case cannotReadVideo
    case noFramesWritten([PortraitVideoExportFailedPhoto])
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return "No photos match this date range."
        case .noImageAsset:
            return "One of the selected photos has no still image asset."
        case .cannotCreatePixelBuffer:
            return "Unable to create a video frame buffer."
        case .cannotCreateImageContext:
            return "Unable to create a video drawing context."
        case .cannotReadImage:
            return "Unable to read one of the still images."
        case .cannotReadVideo:
            return "Unable to read one of the favorite Live Photo videos."
        case .noFramesWritten:
            return "No photos could be written to the video."
        case .writerFailed(let message):
            return message
        }
    }
}

nonisolated enum PortraitVideoExportQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case compact
    case best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .best:
            return "Best"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "Smaller file"
        case .best:
            return "Higher quality"
        }
    }

    var averageBitRate: Int {
        switch self {
        case .compact:
            return 2_800_000
        case .best:
            return 12_000_000
        }
    }
}

final class PortraitVideoExportService {
    static let shared = PortraitVideoExportService()
    nonisolated private static let livePhotoVideoTailDuration: TimeInterval = 1.5
    nonisolated private static let pausedSessionStorageKey = "portraitVideoPausedExportSession"
    nonisolated private static let pausedSessionStagingStorageKey = "portraitVideoPausedExportSessionStaging"
    nonisolated private static let checkpointPhotoInterval = 5

    private let cloudKitService = CloudKitService.shared
    private let outputSize = CGSize(width: 1080, height: 1620)
    private let thumbnailMaxPixelSize = 3240
    private let maximumPhotoAttempts = 3

    private init() {}

    nonisolated func pausedSession() -> PortraitVideoExportPausedSession? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.pausedSessionStorageKey) ??
            defaults.data(forKey: Self.pausedSessionStagingStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(PortraitVideoExportPausedSession.self, from: data)
    }

    nonisolated func discardPausedSession(_ session: PortraitVideoExportPausedSession? = nil) {
        let sessionToDiscard = session ?? pausedSession()
        UserDefaults.standard.removeObject(forKey: Self.pausedSessionStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedSessionStagingStorageKey)

        if let sessionToDiscard {
            try? FileManager.default.removeItem(at: pausedExportDirectoryURL(for: sessionToDiscard.id))
        }
    }

    nonisolated func deleteTemporaryExports() {
        let directoryURL = temporaryExportDirectoryURL()
        let pausedDirectoryToKeep = pausedSession().map { pausedExportDirectoryURL(for: $0.id).lastPathComponent }
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            if fileURL.lastPathComponent == pausedDirectoryToKeep {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @concurrent
    nonisolated func createVideo(
        from photos: [PortraitVideoExportItem],
        configuration: PortraitVideoExportConfiguration,
        resuming pausedSession: PortraitVideoExportPausedSession? = nil,
        shouldPause: @escaping @MainActor () -> Bool = { false },
        progress: @escaping @MainActor (PortraitVideoExportProgress) -> Void
    ) async throws -> PortraitVideoExportResponse {
        guard !photos.isEmpty else { throw PortraitVideoExportError.noPhotos }

        let sortedPhotos = photos.sorted { lhs, rhs in
            if lhs.captureDate == rhs.captureDate {
                return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
            }
            return lhs.captureDate < rhs.captureDate
        }
        var workEstimate = makeWorkEstimate(
            for: sortedPhotos,
            includesFavoriteLivePhotoVideo: configuration.includesFavoriteLivePhotoVideo
        )
        let photoIDs = sortedPhotos.map { $0.objectID.uriRepresentation().absoluteString }
        let sessionID = pausedSession?.id ?? UUID()
        let createdAt = pausedSession?.createdAt ?? Date()
        let compatiblePausedSession = compatiblePausedSession(
            pausedSession,
            photoIDs: photoIDs,
            configuration: configuration
        )
        let previousSegmentFileNames = compatiblePausedSession?.segmentFileNames ?? []
        var segmentFileNames = previousSegmentFileNames
        var failedPhotos = compatiblePausedSession?.failedPhotos ?? []
        var completedPhotoCount = min(compatiblePausedSession?.completedPhotoCount ?? 0, sortedPhotos.count)
        let resumedCompletedPhotoCount = completedPhotoCount
        let resumedFailedPhotos = failedPhotos
        let pausedDirectoryURL = pausedExportDirectoryURL(for: sessionID)
        try FileManager.default.createDirectory(at: pausedDirectoryURL, withIntermediateDirectories: true)
        var segmentWriter = try makeSegmentWriter(
            in: pausedDirectoryURL,
            segmentIndex: segmentFileNames.count,
            quality: configuration.quality
        )
        var hasOpenSegmentWriter = true
        var lastStoredCompletedPhotoCount = resumedCompletedPhotoCount
        var lastStoredFailedPhotos = resumedFailedPhotos

        await progress(
            PortraitVideoExportProgress(
                completedPhotoCount: completedPhotoCount,
                totalPhotoCount: sortedPhotos.count,
                phase: .preparing,
                completedWorkUnitCount: workEstimate.completedWorkUnitCount(before: completedPhotoCount),
                totalWorkUnitCount: workEstimate.totalWorkUnitCount
            )
        )

        do {
            var writtenFrameCount = 0
            let outputFrameRate = max(clampedPicturesPerSecond(configuration.picturesPerSecond), 30)
            let stillFrameCount = max(1, Int((Double(outputFrameRate) / Double(clampedPicturesPerSecond(configuration.picturesPerSecond))).rounded()))
            let heartedStillFrameCount = outputFrameRate

            for (index, photo) in sortedPhotos.enumerated().dropFirst(completedPhotoCount) {
                try Task.checkCancellation()
                if await shouldPause() {
                    return try await pauseExport(
                        segmentWriter: segmentWriter,
                        writtenFrameCount: writtenFrameCount,
                        sessionID: sessionID,
                        createdAt: createdAt,
                        configuration: configuration,
                        photoIDs: photoIDs,
                        completedPhotoCount: completedPhotoCount,
                        segmentFileNames: segmentFileNames,
                        failedPhotos: failedPhotos
                    )
                }

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .loading,
                        completedWorkUnitCount: workEstimate.completedWorkUnitCount(before: index),
                        totalWorkUnitCount: workEstimate.totalWorkUnitCount
                    )
                )

                let photoStartedAt = Date()
                do {
                    let bannerText = await Self.makeBannerText(
                        for: photo,
                        includesDate: configuration.includesDateBanner,
                        includesLocation: configuration.includesLocationBanner
                    )

                    if configuration.includesFavoriteLivePhotoVideo,
                       photo.hasFavoriteLivePhotoVideo,
                       let livePhotoVideoAssetName = photo.livePhotoVideoAssetName {
                        let appendedFrameCount = try await appendLivePhotoVideoWithRetries(
                            named: livePhotoVideoAssetName,
                            bannerText: bannerText,
                            atFrameIndex: writtenFrameCount,
                            outputFrameRate: outputFrameRate,
                            input: segmentWriter.input,
                            adaptor: segmentWriter.adaptor
                        )
                        writtenFrameCount += appendedFrameCount
                    } else {
                        guard let assetName = photo.fullImageAssetName else {
                            throw PortraitVideoExportError.noImageAsset
                        }

                        let image = try await loadImageWithRetries(named: assetName)
                        let frameCount = configuration.holdsHeartedPhotos && photo.isHearted
                            ? heartedStillFrameCount
                            : stillFrameCount
                        try await retryPhotoOperation {
                            try await appendStillPhoto(
                                image,
                                bannerText: bannerText,
                                atFrameIndex: writtenFrameCount,
                                frameCount: frameCount,
                                outputFrameRate: outputFrameRate,
                                input: segmentWriter.input,
                                adaptor: segmentWriter.adaptor
                            )
                        }
                        writtenFrameCount += frameCount
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedPhotos.append(
                        PortraitVideoExportFailedPhoto(
                            photo: photo,
                            reason: failureReason(for: error)
                        )
                    )

                    if segmentWriter.writer.status == .failed || segmentWriter.writer.status == .cancelled {
                        throw PortraitVideoExportError.writerFailed(segmentWriter.writer.error?.localizedDescription ?? "Video export failed.")
                    }
                }
                completedPhotoCount = index + 1
                workEstimate.recordPhotoDuration(
                    at: index,
                    duration: Date().timeIntervalSince(photoStartedAt)
                )

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index + 1,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .writing,
                        completedWorkUnitCount: workEstimate.completedWorkUnitCount(through: index),
                        totalWorkUnitCount: workEstimate.totalWorkUnitCount
                    )
                )

                if completedPhotoCount < sortedPhotos.count,
                   completedPhotoCount.isMultiple(of: Self.checkpointPhotoInterval) {
                    let checkpoint = try await checkpointExport(
                        segmentWriter: segmentWriter,
                        writtenFrameCount: writtenFrameCount,
                        sessionID: sessionID,
                        createdAt: createdAt,
                        configuration: configuration,
                        photoIDs: photoIDs,
                        completedPhotoCount: completedPhotoCount,
                        segmentFileNames: segmentFileNames,
                        failedPhotos: failedPhotos
                    )
                    segmentFileNames = checkpoint.segmentFileNames
                    lastStoredCompletedPhotoCount = checkpoint.session.completedPhotoCount
                    lastStoredFailedPhotos = checkpoint.session.failedPhotos
                    hasOpenSegmentWriter = false
                    segmentWriter = try makeSegmentWriter(
                        in: pausedDirectoryURL,
                        segmentIndex: segmentFileNames.count,
                        quality: configuration.quality
                    )
                    hasOpenSegmentWriter = true
                    writtenFrameCount = 0
                }

                if await shouldPause() {
                    return try await pauseExport(
                        segmentWriter: segmentWriter,
                        writtenFrameCount: writtenFrameCount,
                        sessionID: sessionID,
                        createdAt: createdAt,
                        configuration: configuration,
                        photoIDs: photoIDs,
                        completedPhotoCount: completedPhotoCount,
                        segmentFileNames: segmentFileNames,
                        failedPhotos: failedPhotos
                    )
                }
            }

            if writtenFrameCount > 0 {
                segmentFileNames.append(try await finishSegment(segmentWriter))
            } else {
                cancelSegment(segmentWriter)
            }
            hasOpenSegmentWriter = false

            guard !segmentFileNames.isEmpty else {
                throw PortraitVideoExportError.noFramesWritten(failedPhotos)
            }

            await progress(
                PortraitVideoExportProgress(
                    completedPhotoCount: sortedPhotos.count,
                    totalPhotoCount: sortedPhotos.count,
                    phase: .finishing,
                    completedWorkUnitCount: workEstimate.totalWorkUnitCount,
                    totalWorkUnitCount: workEstimate.totalWorkUnitCount
                )
            )

            workEstimate.saveCalibration()
            let outputURL = try makeOutputURL()
            let segmentURLs = segmentFileNames.map { pausedDirectoryURL.appendingPathComponent($0) }
            try await moveOrConcatenateSegments(segmentURLs, to: outputURL)
            discardPausedSession(
                PortraitVideoExportPausedSession(
                    id: sessionID,
                    createdAt: createdAt,
                    updatedAt: Date(),
                    configuration: configuration,
                    photoIDs: photoIDs,
                    completedPhotoCount: completedPhotoCount,
                    segmentFileNames: segmentFileNames,
                    failedPhotos: failedPhotos
                )
            )
            return .completed(PortraitVideoExportResult(videoURL: outputURL, failedPhotos: failedPhotos))
        } catch is CancellationError {
            if hasOpenSegmentWriter {
                cancelSegment(segmentWriter)
            }

            if await shouldPause() {
                return try storePausedSession(
                    id: sessionID,
                    createdAt: createdAt,
                    configuration: configuration,
                    photoIDs: photoIDs,
                    completedPhotoCount: lastStoredCompletedPhotoCount,
                    segmentFileNames: segmentFileNames,
                    failedPhotos: lastStoredFailedPhotos
                )
            }

            throw CancellationError()
        } catch {
            if hasOpenSegmentWriter {
                cancelSegment(segmentWriter)
            }
            throw error
        }
    }

    nonisolated private func compatiblePausedSession(
        _ session: PortraitVideoExportPausedSession?,
        photoIDs: [String],
        configuration: PortraitVideoExportConfiguration
    ) -> PortraitVideoExportPausedSession? {
        guard let session,
              session.photoIDs == photoIDs,
              session.configuration == configuration,
              session.completedPhotoCount <= photoIDs.count else {
            return nil
        }

        let directoryURL = pausedExportDirectoryURL(for: session.id)
        let segmentFilesExist = session.segmentFileNames.allSatisfy { fileName in
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(fileName).path)
        }
        guard segmentFilesExist else { return nil }

        return session
    }

    nonisolated private func pauseExport(
        segmentWriter: PortraitVideoSegmentWriter,
        writtenFrameCount: Int,
        sessionID: UUID,
        createdAt: Date,
        configuration: PortraitVideoExportConfiguration,
        photoIDs: [String],
        completedPhotoCount: Int,
        segmentFileNames: [String],
        failedPhotos: [PortraitVideoExportFailedPhoto]
    ) async throws -> PortraitVideoExportResponse {
        var pausedSegmentFileNames = segmentFileNames

        if writtenFrameCount > 0 {
            pausedSegmentFileNames.append(try await finishSegment(segmentWriter))
        } else {
            cancelSegment(segmentWriter)
        }

        return try storePausedSession(
            id: sessionID,
            createdAt: createdAt,
            configuration: configuration,
            photoIDs: photoIDs,
            completedPhotoCount: completedPhotoCount,
            segmentFileNames: pausedSegmentFileNames,
            failedPhotos: failedPhotos
        )
    }

    nonisolated private func checkpointExport(
        segmentWriter: PortraitVideoSegmentWriter,
        writtenFrameCount: Int,
        sessionID: UUID,
        createdAt: Date,
        configuration: PortraitVideoExportConfiguration,
        photoIDs: [String],
        completedPhotoCount: Int,
        segmentFileNames: [String],
        failedPhotos: [PortraitVideoExportFailedPhoto]
    ) async throws -> (session: PortraitVideoExportPausedSession, segmentFileNames: [String]) {
        var checkpointSegmentFileNames = segmentFileNames

        if writtenFrameCount > 0 {
            checkpointSegmentFileNames.append(try await finishSegment(segmentWriter))
        } else {
            cancelSegment(segmentWriter)
        }

        let session = try writePausedSession(
            id: sessionID,
            createdAt: createdAt,
            configuration: configuration,
            photoIDs: photoIDs,
            completedPhotoCount: completedPhotoCount,
            segmentFileNames: checkpointSegmentFileNames,
            failedPhotos: failedPhotos
        )
        return (session, checkpointSegmentFileNames)
    }

    nonisolated private func storePausedSession(
        id: UUID,
        createdAt: Date,
        configuration: PortraitVideoExportConfiguration,
        photoIDs: [String],
        completedPhotoCount: Int,
        segmentFileNames: [String],
        failedPhotos: [PortraitVideoExportFailedPhoto]
    ) throws -> PortraitVideoExportResponse {
        .paused(
            try writePausedSession(
                id: id,
                createdAt: createdAt,
                configuration: configuration,
                photoIDs: photoIDs,
                completedPhotoCount: completedPhotoCount,
                segmentFileNames: segmentFileNames,
                failedPhotos: failedPhotos
            )
        )
    }

    nonisolated private func writePausedSession(
        id: UUID,
        createdAt: Date,
        configuration: PortraitVideoExportConfiguration,
        photoIDs: [String],
        completedPhotoCount: Int,
        segmentFileNames: [String],
        failedPhotos: [PortraitVideoExportFailedPhoto]
    ) throws -> PortraitVideoExportPausedSession {
        let session = PortraitVideoExportPausedSession(
            id: id,
            createdAt: createdAt,
            updatedAt: Date(),
            configuration: configuration,
            photoIDs: photoIDs,
            completedPhotoCount: completedPhotoCount,
            segmentFileNames: segmentFileNames,
            failedPhotos: failedPhotos
        )
        let data = try JSONEncoder().encode(session)
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.pausedSessionStagingStorageKey)
        defaults.set(data, forKey: Self.pausedSessionStorageKey)
        defaults.removeObject(forKey: Self.pausedSessionStagingStorageKey)
        return session
    }

    nonisolated private func makeSegmentWriter(
        in directoryURL: URL,
        segmentIndex: Int,
        quality: PortraitVideoExportQuality
    ) throws -> PortraitVideoSegmentWriter {
        let fileName = "segment_\(segmentIndex).mp4"
        let fileURL = directoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: quality.averageBitRate,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(input) else {
            throw PortraitVideoExportError.writerFailed("Unable to configure video writer.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw PortraitVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unable to start video writer.")
        }
        writer.startSession(atSourceTime: .zero)

        return PortraitVideoSegmentWriter(
            writer: writer,
            input: input,
            adaptor: adaptor,
            fileURL: fileURL,
            fileName: fileName
        )
    }

    nonisolated private func finishSegment(_ segmentWriter: PortraitVideoSegmentWriter) async throws -> String {
        segmentWriter.input.markAsFinished()
        await finishWriting(segmentWriter.writer)

        if segmentWriter.writer.status == .failed || segmentWriter.writer.status == .cancelled {
            throw PortraitVideoExportError.writerFailed(
                segmentWriter.writer.error?.localizedDescription ?? "Video export failed."
            )
        }

        return segmentWriter.fileName
    }

    nonisolated private func cancelSegment(_ segmentWriter: PortraitVideoSegmentWriter) {
        segmentWriter.writer.cancelWriting()
        try? FileManager.default.removeItem(at: segmentWriter.fileURL)
    }

    nonisolated private func moveOrConcatenateSegments(_ segmentURLs: [URL], to outputURL: URL) async throws {
        guard let firstSegmentURL = segmentURLs.first else {
            throw PortraitVideoExportError.writerFailed("Unable to finish video export.")
        }

        if segmentURLs.count == 1 {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: firstSegmentURL, to: outputURL)
            return
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PortraitVideoExportError.writerFailed("Unable to combine paused video segments.")
        }

        var insertionTime = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw PortraitVideoExportError.writerFailed("Unable to read a paused video segment.")
            }

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: insertionTime
            )
            insertionTime = insertionTime + duration
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw PortraitVideoExportError.writerFailed("Unable to combine paused video segments.")
        }

        exportSession.shouldOptimizeForNetworkUse = true
        try await exportSession.export(to: outputURL, as: .mp4)
    }

    nonisolated private func makeWorkEstimate(
        for photos: [PortraitVideoExportItem],
        includesFavoriteLivePhotoVideo: Bool
    ) -> PortraitVideoExportWorkEstimate {
        PortraitVideoExportWorkEstimate(
            photoReadKinds: photos.map { photo in
                let exportAssetName = if includesFavoriteLivePhotoVideo, photo.hasFavoriteLivePhotoVideo {
                    photo.livePhotoVideoAssetName
                } else {
                    photo.fullImageAssetName
                }

                guard let assetName = exportAssetName else {
                    return .local
                }

                return cloudKitService.isAssetAvailableForImmediateRead(named: assetName)
                    ? .local
                    : .remote
            }
        )
    }

    nonisolated private func clampedPicturesPerSecond(_ picturesPerSecond: Int) -> Int {
        min(max(picturesPerSecond, 1), 60)
    }

    nonisolated private func loadImageWithRetries(named assetName: String) async throws -> CGImage {
        try await retryPhotoOperation {
            let imageURL = try await cloudKitService.loadAssetURL(named: assetName)
            defer {
                cloudKitService.discardTemporaryReadableAsset(named: assetName)
            }

            return try loadScaledImage(from: imageURL)
        }
    }

    nonisolated private func appendLivePhotoVideoWithRetries(
        named assetName: String,
        bannerText: PortraitVideoBannerText?,
        atFrameIndex frameIndex: Int,
        outputFrameRate: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws -> Int {
        try await retryPhotoOperation {
            let videoURL = try await cloudKitService.loadAssetURL(named: assetName)
            defer {
                cloudKitService.discardTemporaryReadableAsset(named: assetName)
            }

            return try await appendLivePhotoVideo(
                from: videoURL,
                bannerText: bannerText,
                atFrameIndex: frameIndex,
                outputFrameRate: outputFrameRate,
                input: input,
                adaptor: adaptor
            )
        }
    }

    nonisolated private func retryPhotoOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maximumPhotoAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error

                if attempt < maximumPhotoAttempts {
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                }
            }
        }

        throw lastError ?? PortraitVideoExportError.cannotReadImage
    }

    nonisolated private func appendStillPhoto(
        _ image: CGImage,
        bannerText: PortraitVideoBannerText?,
        atFrameIndex frameIndex: Int,
        frameCount: Int,
        outputFrameRate: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws {
        for frameOffset in 0..<frameCount {
            try Task.checkCancellation()
            try await appendFrame(
                image,
                bannerText: bannerText,
                atFrameIndex: frameIndex + frameOffset,
                outputFrameRate: outputFrameRate,
                input: input,
                adaptor: adaptor
            )
        }
    }

    nonisolated private func appendLivePhotoVideo(
        from videoURL: URL,
        bannerText: PortraitVideoBannerText?,
        atFrameIndex frameIndex: Int,
        outputFrameRate: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds

        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw PortraitVideoExportError.cannotReadVideo
        }

        let trimmedDurationSeconds = min(durationSeconds, Self.livePhotoVideoTailDuration)
        let trimStartSeconds = max(0, durationSeconds - trimmedDurationSeconds)
        let frameCount = max(1, Int((trimmedDurationSeconds * Double(outputFrameRate)).rounded(.up)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixelSize, height: thumbnailMaxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(outputFrameRate * 2))
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(outputFrameRate * 2))

        for frameOffset in 0..<frameCount {
            try Task.checkCancellation()

            let frameTime = CMTime(
                seconds: trimStartSeconds + Double(frameOffset) / Double(outputFrameRate),
                preferredTimescale: 600
            )
            let image = try await generator.image(at: frameTime).image

            try await appendFrame(
                image,
                bannerText: bannerText,
                atFrameIndex: frameIndex + frameOffset,
                outputFrameRate: outputFrameRate,
                input: input,
                adaptor: adaptor
            )
        }

        return frameCount
    }

    nonisolated private func appendFrame(
        _ image: CGImage,
        bannerText: PortraitVideoBannerText?,
        atFrameIndex frameIndex: Int,
        outputFrameRate: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelBufferResult = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard pixelBufferResult == kCVReturnSuccess, let pixelBuffer else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        try draw(image, bannerText: bannerText, into: pixelBuffer)

        let presentationTime = CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(outputFrameRate)
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw PortraitVideoExportError.writerFailed("Unable to append video frame.")
        }
    }

    nonisolated private func draw(_ image: CGImage, bannerText: PortraitVideoBannerText?, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw PortraitVideoExportError.cannotCreateImageContext
        }

        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(frame)
        context.interpolationQuality = .high
        context.draw(image, in: aspectFillRect(for: image, in: frame))

        if let bannerText {
            drawBanner(bannerText, in: context, frame: frame)
        }
    }

    nonisolated private func drawBanner(_ text: PortraitVideoBannerText, in context: CGContext, frame: CGRect) {
        let widestTextCount = max(text.primary.count, text.secondary?.count ?? 0)
        let bannerWidth = min(frame.width - 96, text.hasSecondary || widestTextCount > 16 ? 880 : 620)
        let bannerHeight: CGFloat = text.hasSecondary ? 126 : 82
        let bannerRect = CGRect(
            x: (frame.width - bannerWidth) / 2,
            y: frame.height - bannerHeight - 78,
            width: bannerWidth,
            height: bannerHeight
        )
        let cornerRadius: CGFloat = 32

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 0.68))
        context.addPath(roundedRectPath(bannerRect, cornerRadius: cornerRadius))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.setLineWidth(1)
        context.addPath(roundedRectPath(bannerRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius))
        context.strokePath()
        context.restoreGState()

        if let secondary = text.secondary {
            drawBannerLine(
                text.primary,
                fontSize: 36,
                alpha: 0.98,
                centerY: bannerRect.midY + 22,
                in: context,
                bannerRect: bannerRect
            )
            drawBannerLine(
                secondary,
                fontSize: secondary.count > 28 ? 28 : 30,
                alpha: 0.86,
                centerY: bannerRect.midY - 24,
                in: context,
                bannerRect: bannerRect
            )
        } else {
            drawBannerLine(
                text.primary,
                fontSize: text.primary.count > 28 ? 32 : 36,
                alpha: 0.96,
                centerY: bannerRect.midY,
                in: context,
                bannerRect: bannerRect
            )
        }
    }

    nonisolated private func drawBannerLine(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        centerY: CGFloat,
        in context: CGContext,
        bannerRect: CGRect
    ) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
            kCTKernAttributeName: 0.4
        ]

        guard let attributedText = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return
        }

        let fullLine = CTLineCreateWithAttributedString(attributedText)
        let line = CTLineCreateTruncatedLine(
            fullLine,
            Double(max(bannerRect.width - 56, 1)),
            .end,
            nil
        ) ?? fullLine
        let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let textX = bannerRect.midX - lineBounds.width / 2 - lineBounds.minX
        let textY = centerY - lineBounds.height / 2 - lineBounds.minY

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    nonisolated private func roundedRectPath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    nonisolated private func aspectFillRect(for image: CGImage, in frame: CGRect) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: (frame.width - scaledSize.width) / 2,
            y: (frame.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    nonisolated private func loadScaledImage(from url: URL) throws -> CGImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw PortraitVideoExportError.cannotReadImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PortraitVideoExportError.cannotReadImage
        }

        return image
    }

    nonisolated private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    nonisolated private func makeOutputURL() throws -> URL {
        let directoryURL = temporaryExportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let dateText = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = directoryURL
            .appendingPathComponent("work_in_progress_\(dateText)")
            .appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        return outputURL
    }

    nonisolated private func temporaryExportDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portrait_video_exports", isDirectory: true)
    }

    nonisolated private func pausedExportDirectoryURL(for id: UUID) -> URL {
        temporaryExportDirectoryURL()
            .appendingPathComponent("paused_\(id.uuidString)", isDirectory: true)
    }

    nonisolated private static func dateBannerText(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    nonisolated private static func makeBannerText(
        for photo: PortraitVideoExportItem,
        includesDate: Bool,
        includesLocation: Bool
    ) async -> PortraitVideoBannerText? {
        let dateText = includesDate ? dateBannerText(for: photo.captureDate) : nil
        let locationText = includesLocation ? await locationBannerText(for: photo) : nil

        if let dateText {
            return PortraitVideoBannerText(primary: dateText, secondary: locationText)
        }

        if let locationText {
            return PortraitVideoBannerText(primary: locationText, secondary: nil)
        }

        return nil
    }

    nonisolated private static func locationBannerText(for photo: PortraitVideoExportItem) async -> String? {
        if let locationName = photo.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locationName.isEmpty {
            return locationName
        }

        guard photo.latitude != 0 || photo.longitude != 0 else {
            return nil
        }

        if let cachedLocationName = await LocationNameCacheService.shared.cachedName(
            for: photo.latitude,
            longitude: photo.longitude
        ) {
            return cachedLocationName
        }

        let fallbackText = coordinateBannerText(latitude: photo.latitude, longitude: photo.longitude)
        let location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)

        do {
            let resolvedName = try await resolveLocationName(for: location)
            await LocationNameCacheService.shared.setCachedName(
                resolvedName,
                for: photo.latitude,
                longitude: photo.longitude
            )
            return resolvedName
        } catch {
            return fallbackText
        }
    }

    nonisolated private static func coordinateBannerText(latitude: Double, longitude: Double) -> String {
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    nonisolated private static func resolveLocationName(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return "Pinned location"
        }

        return try await withCheckedThrowingContinuation { continuation in
            request.getMapItems { mapItems, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let resolvedName = mapItems?
                    .compactMap { mapItem in
                        [
                            mapItem.addressRepresentations?.cityWithContext(.short),
                            mapItem.addressRepresentations?.cityName,
                            mapItem.address?.shortAddress,
                            mapItem.name,
                            mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                        ].compactMap { $0 }
                            .first(where: { !$0.isEmpty })
                    }
                    .first ?? "Pinned location"

                continuation.resume(returning: resolvedName)
            }
        }
    }

    nonisolated private func failureReason(for error: Error) -> String {
        if case PortraitVideoExportError.noImageAsset = error {
            return "No still image asset."
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "Failed after \(maximumPhotoAttempts) attempts: \(message)"
    }
}
