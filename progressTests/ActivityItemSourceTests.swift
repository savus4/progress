import Foundation
import LinkPresentation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import progress

struct ActivityItemSourceTests {
    @MainActor
    @Test("Share sources support Objective-C callbacks from a worker queue")
    func backgroundShareCallbacks() async throws {
        let image = try #require(UIImage(systemName: "photo"))
        let url = URL(fileURLWithPath: "/tmp/Progress Photo.heic")
        let data = Data([0, 1, 2, 3])
        let urlSource = URLActivityItemSource(
            url: url, title: "Photo title", subject: "Photo subject", previewImage: image
        )
        let fallbackSource = URLActivityItemSource(
            url: url, title: "Fallback title", previewImage: nil
        )
        let imageSource = ImageActivityItemSource(image: image, title: "Image title")
        let dataSource = HEICDataActivityItemSource(data: data, title: "HEIC title", previewImage: image)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        // Match NSItemProvider's Objective-C entry point, including its Swift
        // isolation thunk. A direct Swift call could miss that runtime crash.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.resume() }
                #expect(Thread.isMainThread == false)
                let selector = #selector(UIActivityItemSource.activityViewController(_:itemForActivityType:))
                let urlPayload = urlSource.perform(selector, with: controller, with: nil)?.takeUnretainedValue()
                let imagePayload = imageSource.perform(selector, with: controller, with: nil)?.takeUnretainedValue()
                let dataPayload = dataSource.perform(selector, with: controller, with: nil)?.takeUnretainedValue()
                #expect(urlPayload as? URL == url)
                #expect(imagePayload as? UIImage === image)
                #expect(dataPayload as? Data == data)

                #expect(urlSource.activityViewController(controller, subjectForActivityType: .mail) == "Photo subject")
                #expect(fallbackSource.activityViewController(controller, subjectForActivityType: .mail) == "Fallback title")
                #expect(dataSource.activityViewController(controller, dataTypeIdentifierForActivityType: nil) == UTType.heic.identifier)
                #expect(urlSource.activityViewControllerPlaceholderItem(controller) as? URL == url)
                #expect(imageSource.activityViewControllerPlaceholderItem(controller) as? UIImage === image)
                #expect(dataSource.activityViewControllerPlaceholderItem(controller) as? Data == data)

                let metadata = urlSource.activityViewControllerLinkMetadata(controller)
                #expect(metadata?.title == "Photo title")
                #expect(metadata?.originalURL == url)
                #expect(metadata?.imageProvider != nil)
                #expect(imageSource.activityViewControllerLinkMetadata(controller)?.title == "Image title")
                #expect(dataSource.activityViewControllerLinkMetadata(controller)?.title == "HEIC title")
                #expect(fallbackSource.activityViewControllerLinkMetadata(controller)?.imageProvider == nil)
            }
        }
    }
}
