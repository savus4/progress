import AVFoundation
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
@Suite("Portrait Video Export Recovery")
struct PortraitVideoExportRecoveryTests {
    @Test("Hidden photos produce no frames or failures, including after pause/resume", arguments: [false, true])
    func excludesHiddenPhotos(resume: Bool) async throws {
        let fixture = try ExportFixture(photoCount: 8, hiddenIndices: [1, 5])
        defer { fixture.close() }
        var completed = 0
        var response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration,
            shouldPause: { resume && completed >= 2 },
            progress: { completed = $0.completedPhotoCount }
        )
        if resume {
            guard case .paused(let session) = response else {
                Issue.record("The export did not pause")
                return
            }
            #expect(session.totalPhotoCount == 6)
            #expect(session.photoIDs.count == 6)
            response = try await fixture.service.createVideo(
                from: fixture.items, configuration: fixture.configuration,
                resuming: session, progress: { _ in }
            )
        }
        guard case .completed(let result) = response else {
            Issue.record("The export did not complete")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        #expect(try await frameCount(in: result.videoURL) == 6)
    }

    @Test("Finishing cancellation keeps the checkpoint consistent through repeated resumes", .timeLimit(.minutes(2)))
    func finishingPauseDoesNotDuplicateTail() async throws {
        let fixture = try ExportFixture(photoCount: 8)
        defer { fixture.close() }
        var pausedSession: PortraitVideoExportPausedSession?
        var originalSegmentFileNames: [String]?

        for _ in 0..<3 {
            var pauseRequested = false
            let sessionToResume = pausedSession
            let task = Task {
                try await fixture.service.createVideo(
                    from: fixture.items,
                    configuration: fixture.configuration,
                    resuming: sessionToResume,
                    shouldPause: { pauseRequested },
                    progress: { progress in
                        if progress.phase == .finishing {
                            pauseRequested = true
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }
                )
            }
            let response = try await task.value
            guard case .paused(let session) = response else {
                Issue.record("Cancellation at the finishing callback did not preserve a paused export")
                return
            }
            pausedSession = session

            #expect(session.completedPhotoCount == fixture.items.count)
            #expect(session.failedPhotos.isEmpty)
            #expect(fixture.service.pausedSession() == session)
            if let originalSegmentFileNames {
                #expect(session.segmentFileNames == originalSegmentFileNames)
            } else {
                originalSegmentFileNames = session.segmentFileNames
                #expect(session.segmentFileNames.count == 2)
            }

            let segmentDirectory = fixture.exportDirectoryURL
                .appendingPathComponent("paused_\(session.id.uuidString)", isDirectory: true)
            var storedFrameCount = 0
            for fileName in session.segmentFileNames {
                storedFrameCount += try await frameCount(in: segmentDirectory.appendingPathComponent(fileName))
            }
            // Every fixture photo contributes one frame. This compares the saved
            // progress with the media on disk, rather than its bookkeeping alone.
            #expect(storedFrameCount == session.completedPhotoCount)
            #expect(storedFrameCount == fixture.items.count)
        }

        let session = try #require(pausedSession)
        let resumed = try await fixture.service.createVideo(
            from: fixture.items,
            configuration: fixture.configuration,
            resuming: session,
            progress: { _ in }
        )
        guard case .completed(let result) = resumed else {
            Issue.record("The finishing checkpoint could not be resumed")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        let finalFrameCount = try await frameCount(in: result.videoURL)
        #expect(finalFrameCount == fixture.items.count)
        let duration = try await AVURLAsset(url: result.videoURL).load(.duration).seconds
        #expect(abs(duration - Double(fixture.items.count) / 30) < 0.02)
        #expect(fixture.service.pausedSession() == nil)
    }

    nonisolated private func frameCount(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        let didStartReading = reader.startReading()
        try #require(didStartReading)
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil {
                count += CMSampleBufferGetNumSamples(sample)
            }
        }
        #expect(reader.status == .completed)
        return count
    }

    private final class ExportFixture {
        let service: PortraitVideoExportService
        let items: [PortraitVideoExportItem]
        let configuration: PortraitVideoExportConfiguration
        let directoryURL: URL
        let exportDirectoryURL: URL

        init(photoCount: Int, hiddenIndices: Set<Int> = []) throws {
            let fixtureID = UUID().uuidString
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExportRecovery-\(fixtureID)", isDirectory: true)
            exportDirectoryURL = directoryURL.appendingPathComponent("exports", isDirectory: true)
            let cloud = CloudKitService(
                stagingDirectoryURL: directoryURL.appendingPathComponent("staging", isDirectory: true),
                temporaryReadableAssetsDirectoryURL: directoryURL.appendingPathComponent("readable", isDirectory: true),
                legacyAssetDirectoryURLs: []
            )
            service = PortraitVideoExportService(
                cloudKitService: cloud,
                exportDirectoryURL: exportDirectoryURL,
                pausedSessionStorageKey: "export-recovery-\(fixtureID)",
                pausedSessionStagingStorageKey: "export-recovery-staging-\(fixtureID)"
            )
            let persistence = PersistenceController(inMemory: true)
            let context = persistence.container.viewContext
            let entity = try #require(persistence.container.managedObjectModel.entitiesByName["DailyPhoto"])
            var photos: [DailyPhoto] = []
            for index in 0..<photoCount {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { renderer in
                    UIColor(hue: CGFloat(index) / CGFloat(photoCount), saturation: 1, brightness: 1, alpha: 1).setFill()
                    renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
                }
                let imageData = try #require(image.jpegData(compressionQuality: 0.8))
                let assetName = "recovery-\(fixtureID)-\(index).jpg"
                _ = try cloud.stageAssetData(imageData, named: assetName)
                let photo = DailyPhoto(entity: entity, insertInto: context)
                photo.id = UUID()
                photo.captureDate = Date(timeIntervalSince1970: Double(index) * 86_400)
                photo.fullImageAssetName = assetName
                photo.isHiddenFromVideo = hiddenIndices.contains(index)
                photos.append(photo)
            }
            try context.save()
            let exportItems = photos.map(PortraitVideoExportItem.init(photo:))
            items = exportItems
            configuration = PortraitVideoExportConfiguration(
                picturesPerSecond: 30, quality: .compact,
                includesDateBanner: false, includesLocationBanner: false,
                includesFavoriteLivePhotoVideo: false, holdsHeartedPhotos: false,
                usesAllPhotos: true, startDate: exportItems[0].captureDate, endDate: exportItems[photoCount - 1].captureDate
            )
        }

        func close() {
            service.discardPausedSession()
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}

@MainActor
@Suite("Generated Video Ownership")
struct PortraitVideoExportedVideoTests {
    @Test("Files cancellation retains the generated file for retry", arguments: [false, true])
    func cancelledFilesExportKeepsVideo(notifiesDelegate: Bool) throws {
        let fixture = try FileFixture()
        defer { fixture.close() }
        var video = PortraitVideoExportedVideo(url: fixture.url)
        let coordinator = ExportDocumentPicker.Coordinator {
            _ = video.filesExporterDidComplete(didExport: $0)
        }
        let picker = UIDocumentPickerViewController(forExporting: [fixture.url], asCopy: true)
        if notifiesDelegate {
            coordinator.documentPickerWasCancelled(picker)
        }

        #expect(video.url == fixture.url)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        if FileManager.default.fileExists(atPath: fixture.url.path) {
            #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        }
    }

    @Test("A successful Files export releases the generated temporary file")
    func savedFilesExportReleasesVideo() throws {
        let fixture = try FileFixture()
        defer { fixture.close() }
        var video = PortraitVideoExportedVideo(url: fixture.url)
        var didExport = false
        let coordinator = ExportDocumentPicker.Coordinator {
            didExport = $0
            _ = video.filesExporterDidComplete(didExport: $0)
        }
        let picker = UIDocumentPickerViewController(forExporting: [fixture.url], asCopy: true)
        coordinator.documentPicker(picker, didPickDocumentsAt: [fixture.url])

        #expect(didExport)
        #expect(video.url == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test("Explicit discard releases the generated file")
    func discardReleasesVideo() throws {
        let fixture = try FileFixture()
        defer { fixture.close() }
        var video = PortraitVideoExportedVideo(url: fixture.url)

        video.discard()

        #expect(video.url == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    private struct FileFixture {
        let url: URL
        let bytes = Data([0x00, 0x01, 0x02, 0x03])

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("files-export-\(UUID()).mp4")
            try bytes.write(to: url)
        }

        func close() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
