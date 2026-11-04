import AVFoundation
import Testing
import UIKit
@testable import progress

@MainActor
@Suite(.serialized)
struct PortraitVideoMirroringTests {
    @Test("Still and Live Photo frames reflect while banners stay readable across restored exports")
    func mirroredFrames() async throws {
        var frames: [[CGImage]] = []
        for mirrored in [false, true] {
            let fixture = try PortraitVideoExportFixture(
                photoCount: 3, livePhotoIndices: [1], picturesPerSecond: 1,
                mirrorsPhotos: mirrored, includesDateBanner: true
            )
            defer { fixture.close() }
            // Asymmetry makes a missing or doubled reflection observable. The
            // symmetric gray banner background lets us compare text separately.
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image { renderer in
                UIColor.gray.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
                UIColor.red.setFill()
                renderer.fill(CGRect(x: 0, y: 160, width: 160, height: 320))
                UIColor.blue.setFill()
                renderer.fill(CGRect(x: 160, y: 160, width: 160, height: 320))
            }
            let sourceURL = fixture.directoryURL.appendingPathComponent("staging/recovery-0.jpg")
            let original = try #require(image.jpegData(compressionQuality: 1))
            try original.write(to: sourceURL)
            var completed = 0
            let response = try await fixture.service.createVideo(
                from: fixture.items, configuration: fixture.configuration,
                shouldPause: { completed >= 2 }, progress: { completed = $0.completedPhotoCount }
            )
            guard case .paused(let session) = response else {
                Issue.record("Export did not pause")
                return
            }
            try fixture.reopen()
            let restored = try #require(fixture.service.pausedSession())
            #expect(restored.configuration.mirrorsPhotos == mirrored)
            let result = try await fixture.service.createVideo(
                from: fixture.items, configuration: restored.configuration,
                resuming: restored, progress: { _ in }
            )
            guard case .completed(let export) = result else {
                Issue.record("Export did not resume")
                return
            }
            #expect(session == restored)
            #expect(export.failedPhotos.isEmpty)
            #expect(try Data(contentsOf: sourceURL) == original)
            let asset = AVURLAsset(url: export.videoURL)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            var samples: [CGImage] = []
            for seconds in [0.1, 1.2] {
                samples.append(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
            }
            frames.append(samples)
        }
        for index in 0..<2 {
            // Exclude the banner area when comparing reflected photo pixels.
            let region = CGRect(x: 0, y: 600, width: 1080, height: 1000)
            let normal = try pixels(frames[0][index], region: region)
            let mirrored = try pixels(frames[1][index], region: region, reflect: true)
            #expect(meanDifference(normal, mirrored) < 12)
        }
        let banner = CGRect(x: 200, y: 75, width: 680, height: 100)
        let normal = try pixels(frames[0][0], region: banner)
        let mirrored = try pixels(frames[1][0], region: banner)
        #expect(meanDifference(normal, mirrored) < 8, "Date text must keep its normal direction.")
    }

    private func pixels(_ image: CGImage, region: CGRect, reflect: Bool = false) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = try #require(CGContext(data: &bytes, width: 64, height: 64, bitsPerComponent: 8,
                                            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if reflect {
            context.translateBy(x: 64, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return bytes
    }

    private func meanDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        Double(zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(lhs.count)
    }
}
