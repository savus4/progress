import AVFoundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import progress

@MainActor
struct LivePhotoExportMirroringTests {
    @Test("Mirrored Live Photo derivatives preserve pairing, still time, audio, and source bytes", arguments: [false, true])
    func pairedResources(rotated: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = UUID().uuidString
        let imageURL = directory.appendingPathComponent("photo.jpg")
        let movieURL = directory.appendingPathComponent("photo.mov")
        let generatedURL = directory.appendingPathComponent("generated.mov")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { renderer in
            UIColor.red.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 16, height: 48))
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 16, y: 0, width: 16, height: 48))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        try await writeMovie(image: image, identifier: identifier, rotated: rotated, to: generatedURL)

        let source = AVURLAsset(url: generatedURL)
        let composition = AVMutableComposition()
        let sourceMetadata = try await source.load(.metadata)
        let audioURL = try #require(Bundle(for: PortraitVideoExportFixture.self).url(forResource: "live-photo-audio", withExtension: "mov"))
        let audio = AVURLAsset(url: audioURL)
        var tracks = try await source.load(.tracks)
        tracks += try await audio.loadTracks(withMediaType: .audio)
        for track in tracks {
            let output = try #require(composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = try await track.load(.timeRange)
            try output.insertTimeRange(range, of: track, at: range.start)
            if track.mediaType == .video { output.preferredTransform = try await track.load(.preferredTransform) }
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.metadata = sourceMetadata
        try await session.export(to: movieURL, as: .mov)
        let originalImage = try Data(contentsOf: imageURL)
        let originalMovie = try Data(contentsOf: movieURL)
        let result = try await PhotoExportMirroring.prepare(imageURL: imageURL, videoURL: movieURL, mirrored: true)
        defer { result.removeTemporaryFiles() }
        #expect(try Data(contentsOf: imageURL) == originalImage)
        #expect(try Data(contentsOf: movieURL) == originalMovie)
        let imageSource = try #require(CGImageSourceCreateWithURL(result.imageURL as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        let maker = try #require(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        #expect(maker["17"] as? String == identifier)
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == 2)
        let asset = AVURLAsset(url: try #require(result.videoURL))
        let metadata = try await asset.load(.metadata)
        let contentID = try #require(metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier })
        #expect(try await contentID.load(.stringValue) == identifier)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let metadataTrack = try #require(try await asset.loadTracks(withMediaType: .metadata).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: metadataTrack, outputSettings: nil)
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        try #require(reader.startReading())
        let group = try #require(adaptor.nextTimedMetadataGroup())
        #expect(abs(group.timeRange.start.seconds - 0.5) < 0.01)
        #expect(group.items.first?.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time")
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let transform = try await videoTrack.load(.preferredTransform)
        #expect(transform.a * transform.d - transform.b * transform.c < 0)
        let originalGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        originalGenerator.appliesPreferredTrackTransform = true
        let reflectedGenerator = AVAssetImageGenerator(asset: asset)
        reflectedGenerator.appliesPreferredTrackTransform = true
        let time = CMTime(value: 1, timescale: 2)
        let originalFrame = try await originalGenerator.image(at: time).image
        let reflectedFrame = try await reflectedGenerator.image(at: time).image
        let expected = pixels(UIImage(cgImage: originalFrame).withHorizontallyFlippedOrientation())
        let actual = pixels(UIImage(cgImage: reflectedFrame))
        #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 10 })
    }

    private func pixels(_ image: UIImage) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return Array(rendered.cgImage!.dataProvider!.data! as Data)
    }

    private func writeMovie(image: UIImage, identifier: String, rotated: Bool, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        contentID.value = identifier as NSString
        writer.metadata = [contentID]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 48
        ])
        if rotated { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0) }
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(video)
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_SInt8
            ]] as CFArray, formatDescriptionOut: &description
        )
        try #require(status == noErr)
        let timed = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        writer.add(timed)
        let metadata = AVAssetWriterInputMetadataAdaptor(assetWriterInput: timed)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let stillTime = AVMutableMetadataItem()
        stillTime.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        stillTime.value = NSNumber(value: Int8(-1))
        let group = AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(
            start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 30)
        ))
        while !timed.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        try #require(metadata.append(group))
        timed.markAsFinished()
        for frame in 0..<3 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(pixels.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 32, height: 48,
                                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.draw(try #require(image.cgImage), in: CGRect(x: 0, y: 0, width: 32, height: 48))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            try #require(pixels.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        video.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
