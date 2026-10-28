import AVFoundation
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
@Suite("Portrait Video Export Recovery")
struct PortraitVideoExportRecoveryTests {
    @Test("Photo order and hidden exclusions survive pause/resume", arguments: [false, true], [false, true])
    func exportsPhotoSequence(resume: Bool, reverse: Bool) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8, hiddenIndices: [1, 5], reversesPhotoOrder: reverse)
        defer { fixture.close() }
        var completed = 0
        var response = try await fixture.service.createVideo(
            from: Array(fixture.items.reversed()), configuration: fixture.configuration,
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
            #expect(session.configuration.reversesPhotoOrder == reverse)
            #expect(fixture.service.pausedSession() == session)
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
        var expectedIndices = [0, 2, 3, 4, 6, 7]
        if reverse {
            expectedIndices.reverse()
        }
        try await expectFrames(in: result.videoURL, indices: expectedIndices, photoCount: 8)
    }

    @Test("Reopening the library and exporter reuses completed media without its source photos", arguments: [false, true])
    func restoredExportSkipsCompletedPhotos(reverse: Bool) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8, reversesPhotoOrder: reverse)
        defer { fixture.close() }
        let original = try #require(try await pause(fixture, after: 3))
        try #require(original.completedPhotoCount == 3)
        let segmentURL = fixture.pausedDirectory(for: original).appendingPathComponent(try #require(original.segmentFileNames.first))
        let savedMedia = try Data(contentsOf: segmentURL)
        try fixture.removeSources(for: fixture.orderedItems.prefix(3))
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        #expect(restored == original)
        #expect(restored.photoIDs == fixture.orderedItems.map { $0.objectID.uriRepresentation().absoluteString })
        var progress: [PortraitVideoExportProgress] = []
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: restored.configuration, resuming: restored,
            progress: {
                progress.append($0)
                if $0.phase == .finishing {
                    #expect((try? Data(contentsOf: segmentURL)) == savedMedia)
                }
            }
        )
        guard case .completed(let result) = response else {
            Issue.record("The restored export did not complete")
            return
        }
        #expect(progress.first?.completedPhotoCount == 3)
        #expect(progress.filter { $0.phase == .loading }.map(\.completedPhotoCount) == Array(3..<8))
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: reverse ? Array((0..<8).reversed()) : Array(0..<8), photoCount: 8)
        #expect(fixture.service.pausedSession() == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.pausedDirectory(for: restored).path) == false)
    }

    @Test("Cancelling a resume preserves its existing checkpoint and media")
    func cancelledResumePreservesCheckpoint() async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 3))
        let segmentURL = fixture.pausedDirectory(for: saved).appendingPathComponent(try #require(saved.segmentFileNames.first))
        let savedMedia = try Data(contentsOf: segmentURL)
        var updateCount = 0
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.createVideo(
                from: fixture.items, configuration: fixture.configuration, resuming: saved,
                progress: { _ in updateCount += 1 }
            )
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(updateCount == 0)
        #expect(fixture.service.pausedSession() == saved)
        #expect(try Data(contentsOf: segmentURL) == savedMedia)
        try fixture.removeSources(for: fixture.orderedItems.prefix(3))
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: restored, progress: { _ in }
        )
        guard case .completed(let result) = response else {
            Issue.record("The cancelled resume damaged its checkpoint")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: Array(0..<8), photoCount: 8)
    }

    @Test("Cancellation recovers only committed media before and after an automatic checkpoint",
          arguments: [false, true], [2, 7])
    func interruptedWorkResumesFromCheckpoint(requestsPause: Bool, interruptedAfter: Int) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        var shouldPause = false
        let task = Task {
            try await fixture.service.createVideo(
                from: fixture.items, configuration: fixture.configuration,
                shouldPause: { shouldPause },
                progress: { progress in
                    if progress.phase == .loading, progress.completedPhotoCount == interruptedAfter {
                        shouldPause = requestsPause
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }
        if requestsPause {
            let response = try await task.value
            guard case .paused = response else {
                Issue.record("Background fallback cancellation did not preserve a paused export")
                return
            }
        } else {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        try fixture.reopen()
        let checkpoint = fixture.service.pausedSession()
        let committedCount = interruptedAfter >= 5 ? 5 : 0
        if requestsPause || committedCount > 0 {
            let saved = try #require(checkpoint)
            #expect(saved.completedPhotoCount == committedCount)
            #expect(saved.failedPhotos.isEmpty)
            var savedFrameCount = 0
            for name in saved.segmentFileNames {
                savedFrameCount += try await frameCount(in: fixture.pausedDirectory(for: saved).appendingPathComponent(name))
            }
            #expect(savedFrameCount == committedCount)
            let files = try FileManager.default.contentsOfDirectory(atPath: fixture.pausedDirectory(for: saved).path)
            #expect(Set(files) == Set(saved.segmentFileNames), "Uncommitted video segments must be removed.")
        } else {
            #expect(checkpoint == nil)
        }
        if !requestsPause, let checkpoint {
            // A terminated process may leave its current, uncommitted file behind.
            let unfinished = fixture.pausedDirectory(for: checkpoint)
                .appendingPathComponent("segment_\(checkpoint.segmentFileNames.count).mp4")
            try Data("unfinished video segment".utf8).write(to: unfinished)
        }
        try fixture.removeSources(for: fixture.orderedItems.prefix(committedCount))
        var initialProgress: Int?
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: checkpoint,
            progress: { if initialProgress == nil { initialProgress = $0.completedPhotoCount } }
        )
        guard case .completed(let result) = response else {
            Issue.record("The interrupted export did not resume")
            return
        }
        #expect(initialProgress == committedCount)
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: Array(0..<8), photoCount: 8)
    }

    @Test("Repeated pauses cover empty exports, checkpoint boundaries, and a completed tail", arguments: [false, true])
    func repeatedPausesPreserveEveryFrame(reverse: Bool) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8, reversesPhotoOrder: reverse)
        defer { fixture.close() }
        var previousCount = 0
        var session: PortraitVideoExportPausedSession?
        for cutoff in [0, 2, 5, 7, 8] {
            let saved = try #require(try await pause(fixture, after: cutoff, resuming: session))
            #expect(saved.completedPhotoCount == cutoff)
            #expect(saved.failedPhotos.isEmpty)
            try fixture.removeSources(for: fixture.orderedItems[previousCount..<cutoff])
            previousCount = cutoff
            try fixture.reopen()
            let restored = try #require(fixture.service.pausedSession())
            #expect(restored == saved)
            session = restored
        }
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: session, progress: { _ in }
        )
        guard case .completed(let result) = response else {
            Issue.record("The repeatedly paused export did not complete")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: reverse ? Array((0..<8).reversed()) : Array(0..<8), photoCount: 8)
    }

    @Test("Invalid or incompatible checkpoints restart without losing or duplicating photos", arguments: [
        "missing segment", "unreadable segment", "negative progress", "excessive progress",
        "missing segments", "duplicate segments", "zero progress with media",
        "failure outside completed range", "duplicate failures", "changed configuration", "changed selection"
    ])
    func invalidCheckpointRestarts(damage: String) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 2))
        let segmentURL = fixture.pausedDirectory(for: saved).appendingPathComponent(try #require(saved.segmentFileNames.first))
        var selectedPhotos = fixture.items
        switch damage {
        case "missing segment":
            try FileManager.default.removeItem(at: segmentURL)
        case "unreadable segment":
            try Data("truncated mp4".utf8).write(to: segmentURL)
        case "negative progress":
            try fixture.rewriteCheckpoint { $0["completedPhotoCount"] = -1 }
        case "excessive progress":
            try fixture.rewriteCheckpoint { $0["completedPhotoCount"] = 9 }
        case "missing segments":
            try fixture.rewriteCheckpoint { $0["segmentFileNames"] = [] }
        case "duplicate segments":
            try fixture.rewriteCheckpoint { $0["segmentFileNames"] = saved.segmentFileNames + saved.segmentFileNames }
        case "zero progress with media":
            try fixture.rewriteCheckpoint { $0["completedPhotoCount"] = 0 }
        case "failure outside completed range", "duplicate failures":
            let index = damage == "duplicate failures" ? 0 : 7
            let failure = PortraitVideoExportFailedPhoto(photo: fixture.items[index], reason: "Invalid saved failure")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure))
            try fixture.rewriteCheckpoint { $0["failedPhotos"] = damage == "duplicate failures" ? [object, object] : [object] }
        case "changed configuration":
            try fixture.rewriteCheckpoint {
                var configuration = $0["configuration"] as? [String: Any] ?? [:]
                configuration["picturesPerSecond"] = 6
                $0["configuration"] = configuration
            }
        case "changed selection":
            selectedPhotos.removeLast()
        default:
            Issue.record("Unknown checkpoint damage: \(damage)")
            return
        }
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        var initialProgress: Int?
        let response = try await fixture.service.createVideo(
            from: selectedPhotos, configuration: fixture.configuration, resuming: restored,
            progress: { if initialProgress == nil { initialProgress = $0.completedPhotoCount } }
        )
        guard case .completed(let result) = response else {
            Issue.record("The invalid checkpoint prevented a fresh export")
            return
        }
        #expect(initialProgress == 0)
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: Array(0..<selectedPhotos.count), photoCount: 8)
        #expect(fixture.service.pausedSession() == nil)
    }

    @Test("A valid staging checkpoint survives an absent or corrupt main checkpoint", arguments: [false, true])
    func recoversStagingCheckpoint(corruptPrimary: Bool) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 2))
        let defaults = UserDefaults.standard
        let data = try #require(defaults.data(forKey: fixture.sessionStorageKey))
        defaults.set(data, forKey: fixture.stagingStorageKey)
        if corruptPrimary {
            defaults.set(Data("incomplete checkpoint".utf8), forKey: fixture.sessionStorageKey)
        } else {
            defaults.removeObject(forKey: fixture.sessionStorageKey)
        }
        try fixture.removeSources(for: fixture.orderedItems.prefix(2))
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        #expect(restored == saved)
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: restored, progress: { _ in }
        )
        guard case .completed(let result) = response else {
            Issue.record("The staging checkpoint did not resume")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        try await expectFrames(in: result.videoURL, indices: Array(0..<8), photoCount: 8)
        #expect(defaults.data(forKey: fixture.sessionStorageKey) == nil)
        #expect(defaults.data(forKey: fixture.stagingStorageKey) == nil)
    }

    @Test("Failed photos remain recorded once, including checkpoints with no successful frames", arguments: [[1], [0, 1, 2]])
    func resumedFailuresArePreserved(failedIndices: [Int]) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8, missingAssetIndices: Set(failedIndices))
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 3))
        try #require(saved.failedPhotos.count == failedIndices.count)
        #expect(saved.failedPhotos.map(\.id) == failedIndices.map { fixture.items[$0].objectID.uriRepresentation().absoluteString })
        try fixture.removeSources(for: fixture.orderedItems.prefix(3))
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        var initialProgress: Int?
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: restored,
            progress: { if initialProgress == nil { initialProgress = $0.completedPhotoCount } }
        )
        guard case .completed(let result) = response else {
            Issue.record("The export with a skipped photo did not resume")
            return
        }
        #expect(initialProgress == 3)
        #expect(result.failedPhotos == saved.failedPhotos)
        try await expectFrames(in: result.videoURL, indices: (0..<8).filter { !failedIndices.contains($0) }, photoCount: 8)
    }

    @Test("Checkpoint loading prefers valid committed data and rejects two corrupt copies", arguments: [false, true])
    func checkpointCopySelection(corruptPrimary: Bool) async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 2))
        let defaults = UserDefaults.standard
        defaults.set(Data("corrupt staging data".utf8), forKey: fixture.stagingStorageKey)
        if corruptPrimary {
            defaults.set(Data("corrupt committed data".utf8), forKey: fixture.sessionStorageKey)
        }
        try fixture.reopen()
        if corruptPrimary {
            #expect(fixture.service.pausedSession() == nil)
            fixture.service.deleteTemporaryExports()
            #expect(FileManager.default.fileExists(atPath: fixture.pausedDirectory(for: saved).path) == false)
        } else {
            #expect(fixture.service.pausedSession() == saved)
        }
    }

    @Test("Temporary cleanup preserves paused media and explicit discard removes both checkpoint copies")
    func cleanupAndDiscard() async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
        defer { fixture.close() }
        let saved = try #require(try await pause(fixture, after: 2))
        let defaults = UserDefaults.standard
        let data = try #require(defaults.data(forKey: fixture.sessionStorageKey))
        defaults.set(data, forKey: fixture.stagingStorageKey)
        let orphan = fixture.exportDirectoryURL.appendingPathComponent("abandoned.mp4")
        try Data([1, 2, 3]).write(to: orphan)
        fixture.service.deleteTemporaryExports()
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.pausedDirectory(for: saved).path))
        try fixture.reopen()
        #expect(fixture.service.pausedSession() == saved)
        fixture.service.discardPausedSession()
        #expect(fixture.service.pausedSession() == nil)
        #expect(defaults.data(forKey: fixture.sessionStorageKey) == nil)
        #expect(defaults.data(forKey: fixture.stagingStorageKey) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.pausedDirectory(for: saved).path) == false)
    }

    @Test("Finishing cancellation keeps the checkpoint consistent through repeated resumes", .timeLimit(.minutes(2)))
    func finishingPauseDoesNotDuplicateTail() async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 8)
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

    private func pause(
        _ fixture: PortraitVideoExportFixture,
        after completedCount: Int,
        resuming session: PortraitVideoExportPausedSession? = nil
    ) async throws -> PortraitVideoExportPausedSession? {
        var completed = session?.completedPhotoCount ?? 0
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: session,
            shouldPause: { completed >= completedCount },
            progress: { completed = $0.completedPhotoCount }
        )
        guard case .paused(let paused) = response else { return nil }
        return paused
    }

    private func expectFrames(
        in url: URL,
        indices: [Int],
        photoCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let colors = try await frameColors(in: url)
        try #require(colors.count == indices.count, sourceLocation: sourceLocation)
        for (color, index) in zip(colors, indices) {
            let expected = UIColor(hue: CGFloat(index) / CGFloat(photoCount), saturation: 1, brightness: 1, alpha: 1)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            try #require(expected.getRed(&red, green: &green, blue: &blue, alpha: nil), sourceLocation: sourceLocation)
            #expect(abs(color[0] - Double(red)) < 0.08, sourceLocation: sourceLocation)
            #expect(abs(color[1] - Double(green)) < 0.08, sourceLocation: sourceLocation)
            #expect(abs(color[2] - Double(blue)) < 0.08, sourceLocation: sourceLocation)
        }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - Double(indices.count) / 30) < 0.02, sourceLocation: sourceLocation)
    }

    nonisolated private func frameColors(in url: URL) async throws -> [[Double]] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        try #require(reader.startReading())
        var colors: [[Double]] = []
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let offset = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
                + CVPixelBufferGetWidth(buffer) / 2 * 4
            colors.append([Double(bytes[offset + 2]), Double(bytes[offset + 1]), Double(bytes[offset])].map { $0 / 255 })
        }
        #expect(reader.status == .completed)
        return colors
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
