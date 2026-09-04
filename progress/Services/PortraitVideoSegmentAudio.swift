import AVFoundation
import Foundation

/// Owned by one segment writer and accessed sequentially by the export task.
nonisolated final class PortraitVideoSegmentAudio {
    struct Clip {
        let url: URL
        let insertionTime: CMTime
        let duration: CMTime
    }

    private let directoryURL: URL
    private var clips: [Clip] = []

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func prepareClip(
        from asset: AVAsset,
        sourceTimeRange: CMTimeRange,
        at insertionTime: CMTime
    ) async throws -> Clip? {
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil // Live Photos recorded without sound remain silent.
        }
        let availableRange = try await sourceTrack.load(.timeRange)
        let range = CMTimeRangeGetIntersection(sourceTimeRange, otherRange: availableRange)
        guard range.isValid, range.duration > .zero else { return nil }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PortraitVideoExportError.writerFailed("Unable to prepare Live Photo audio.")
        }
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw PortraitVideoExportError.writerFailed("Unable to encode Live Photo audio.")
        }

        // Materialize before the downloaded Live Photo movie is discarded.
        // AAC also gives all checkpoint segments a consistent audio format.
        let url = directoryURL.appendingPathComponent("audio_\(UUID().uuidString).m4a")
        do {
            try Task.checkCancellation()
            try await exporter.export(to: url, as: .m4a)
            try Task.checkCancellation()
            return Clip(
                url: url,
                insertionTime: insertionTime + (range.start - sourceTimeRange.start),
                duration: range.duration
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func commit(_ clip: Clip) {
        clips.append(clip)
    }

    func discard(_ clip: Clip) {
        try? FileManager.default.removeItem(at: clip.url)
    }

    func cleanup() {
        for clip in clips { discard(clip) }
        clips.removeAll()
    }

    func finish(videoURL: URL) async throws -> URL {
        guard !clips.isEmpty else { return videoURL }
        defer { cleanup() }

        let video = AVURLAsset(url: videoURL)
        let duration = try await video.load(.duration)
        let composition = AVMutableComposition()
        try await composition.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: video, at: .zero
        )
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PortraitVideoExportError.writerFailed("Unable to add Live Photo audio to video.")
        }

        for clip in clips {
            try Task.checkCancellation()
            let audio = AVURLAsset(url: clip.url)
            guard let track = try await audio.loadTracks(withMediaType: .audio).first else {
                throw PortraitVideoExportError.writerFailed("Unable to read prepared Live Photo audio.")
            }
            let availableRange = try await track.load(.timeRange)
            let clipDuration = CMTimeMinimum(clip.duration, duration - clip.insertionTime)
            let range = CMTimeRangeGetIntersection(
                CMTimeRange(start: .zero, duration: clipDuration), otherRange: availableRange
            )
            guard range.isValid, range.duration > .zero else { continue }
            // Inserting at the video timestamp preserves silence between clips.
            try audioTrack.insertTimeRange(range, of: track, at: clip.insertionTime + range.start)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw PortraitVideoExportError.writerFailed("Unable to finish video with Live Photo audio.")
        }
        let outputURL = directoryURL.appendingPathComponent("segment_audio_\(UUID().uuidString).mp4")
        do {
            try await exporter.export(to: outputURL, as: .mp4)
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: videoURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
