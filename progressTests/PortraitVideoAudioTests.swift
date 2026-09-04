import AVFoundation
import CoreData
import Testing
import UIKit
@testable import progress

private final class AudioFixtureBundle {}

@Suite(.serialized)
struct PortraitVideoAudioTests {
    @MainActor
    @Test("Live Photo sound survives checkpoints and pause/resume", arguments: [false, true])
    func exportedAudio(resume: Bool) async throws {
        let defaults = UserDefaults.standard
        let savedSession = defaults.data(forKey: "portraitVideoPausedExportSession")
        let savedStaging = defaults.data(forKey: "portraitVideoPausedExportSessionStaging")
        defer {
            defaults.set(savedSession, forKey: "portraitVideoPausedExportSession")
            defaults.set(savedStaging, forKey: "portraitVideoPausedExportSessionStaging")
        }
        // Synthetic fixture: 3 seconds of blue video; silence for the first
        // 1.5 seconds, then a 440 Hz tone (48 kHz AAC). No personal media.
        let fixture = try #require(Bundle(for: AudioFixtureBundle.self).url(
            forResource: "live-photo-audio", withExtension: "mov"
        ))
        let movieName = "audio-test-\(UUID()).mov"
        let imageName = "audio-test-\(UUID()).jpg"
        let cloud = CloudKitService.shared
        _ = try cloud.stageAssetData(Data(contentsOf: fixture), named: movieName)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        }
        _ = try cloud.stageAssetData(try #require(image.jpegData(compressionQuality: 0.8)), named: imageName)
        defer {
            cloud.deleteAsset(named: movieName)
            cloud.deleteAsset(named: imageName)
        }
        let persistence = PersistenceController(inMemory: true)
        let entity = try #require(persistence.container.managedObjectModel.entitiesByName["DailyPhoto"])
        let items = (0..<6).map { index in
            let photo = DailyPhoto(entity: entity, insertInto: persistence.container.viewContext)
            photo.id = UUID()
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 86400)
            photo.fullImageAssetName = imageName
            photo.livePhotoVideoAssetName = movieName
            photo.isFavoriteLivePhoto = index == 1 || index == 5
            return PortraitVideoExportItem(photo: photo)
        }
        let config = PortraitVideoExportConfiguration(
            picturesPerSecond: 1, quality: .compact,
            includesDateBanner: false, includesLocationBanner: false,
            includesFavoriteLivePhotoVideo: true, holdsHeartedPhotos: false,
            usesAllPhotos: true, startDate: items[0].captureDate, endDate: items[5].captureDate
        )
        var completed = 0
        var response = try await PortraitVideoExportService.shared.createVideo(
            from: items, configuration: config,
            shouldPause: { resume && completed >= 3 },
            progress: { completed = $0.completedPhotoCount }
        )
        if resume {
            guard case .paused(let session) = response else {
                Issue.record("Export did not pause")
                return
            }
            #expect(session.audioFormatVersion == 1)
            response = try await PortraitVideoExportService.shared.createVideo(
                from: items, configuration: config, resuming: session, progress: { _ in }
            )
        }
        guard case .completed(let result) = response else {
            Issue.record("Export did not complete")
            return
        }
        defer { try? FileManager.default.removeItem(at: result.videoURL) }
        #expect(result.failedPhotos.isEmpty)
        let asset = AVURLAsset(url: result.videoURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 7) < 0.1)
        let levels = try await audioLevels(asset)
        // Fixture's first half is silent, last 1.5 seconds contain a tone.
        // These windows prove tail selection and sound in both merged segments.
        #expect(levels[1] > 0.05)
        #expect(levels[3] > 0.05)
        #expect(levels[0] < 0.001)
        #expect(levels[2] < 0.001)
    }

    nonisolated private func audioLevels(_ asset: AVAsset) async throws -> [Float] {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        #expect(reader.startReading())
        let windows = [0.2..<0.8, 1.2..<2.3, 2.7..<5.3, 5.7..<6.8]
        var maxima = [Float](repeating: 0, count: windows.count)
        while let sample = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / 48000
                for window in windows.indices where windows[window].contains(time) {
                    maxima[window] = max(maxima[window], abs(value))
                }
            }
        }
        #expect(reader.status == .completed)
        return maxima
    }
}
