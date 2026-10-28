import AVFoundation
import Testing
@testable import progress

@Suite(.serialized)
struct PortraitVideoAudioTests {
    @MainActor
    @Test("Live Photo sound survives checkpoints and restored exports", arguments: [false, true], [false, true])
    func exportedAudio(resume: Bool, reverse: Bool) async throws {
        // Synthetic fixture: silence followed by a 440 Hz tone. Each Live Photo
        // has its own source file so completed sources can be removed on resume.
        let fixture = try PortraitVideoExportFixture(
            photoCount: 6, livePhotoIndices: [1, 5], picturesPerSecond: 1, reversesPhotoOrder: reverse
        )
        defer { fixture.close() }
        var completed = 0
        var response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration,
            shouldPause: { resume && completed >= 3 },
            progress: { completed = $0.completedPhotoCount }
        )
        if resume {
            guard case .paused(let session) = response else {
                Issue.record("Export did not pause")
                return
            }
            #expect(session.audioFormatVersion == 1)
            try fixture.removeSources(for: fixture.orderedItems.prefix(3))
            try fixture.reopen()
            let restored = try #require(fixture.service.pausedSession())
            #expect(restored == session)
            response = try await fixture.service.createVideo(
                from: fixture.items, configuration: restored.configuration, resuming: restored, progress: { _ in }
            )
        }
        guard case .completed(let result) = response else {
            Issue.record("Export did not complete")
            return
        }
        #expect(result.failedPhotos.isEmpty)
        let asset = AVURLAsset(url: result.videoURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 7) < 0.1)
        let levels = try await audioLevels(asset, reverse: reverse)
        // Check audible clips on both sides of the pause, and silence in stills.
        #expect(levels[1] > 0.05)
        #expect(levels[3] > 0.05)
        #expect(levels[0] < 0.001)
        #expect(levels[2] < 0.001)
    }

    @MainActor
    @Test("Legacy silent Live Photo checkpoints are rebuilt with sound")
    func legacyAudioCheckpointRestarts() async throws {
        let fixture = try PortraitVideoExportFixture(photoCount: 6, livePhotoIndices: [1, 5], picturesPerSecond: 1)
        defer { fixture.close() }
        var completed = 0
        let paused = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration,
            shouldPause: { completed >= 3 }, progress: { completed = $0.completedPhotoCount }
        )
        guard case .paused = paused else {
            Issue.record("Export did not pause")
            return
        }
        try fixture.rewriteCheckpoint { $0.removeValue(forKey: "audioFormatVersion") }
        try fixture.reopen()
        let restored = try #require(fixture.service.pausedSession())
        #expect(restored.audioFormatVersion == nil)
        var initialProgress: Int?
        let response = try await fixture.service.createVideo(
            from: fixture.items, configuration: fixture.configuration, resuming: restored,
            progress: { if initialProgress == nil { initialProgress = $0.completedPhotoCount } }
        )
        guard case .completed(let result) = response else {
            Issue.record("The legacy export did not complete")
            return
        }
        #expect(initialProgress == 0)
        #expect(result.failedPhotos.isEmpty)
        let levels = try await audioLevels(AVURLAsset(url: result.videoURL), reverse: false)
        #expect(levels[1] > 0.05)
        #expect(levels[3] > 0.05)
    }

    nonisolated private func audioLevels(_ asset: AVAsset, reverse: Bool) async throws -> [Float] {
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
        let windows = reverse
            ? [1.7..<4.3, 0.2..<1.3, 6.2..<6.8, 4.7..<5.8]
            : [0.2..<0.8, 1.2..<2.3, 2.7..<5.3, 5.7..<6.8]
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
