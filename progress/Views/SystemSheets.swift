import SwiftUI
import UIKit
import LinkPresentation
import UniformTypeIdentifiers
import ImageIO

struct ActivityPresentation: Identifiable {
    let id = UUID()
    let activityItems: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

struct ExportDocumentPicker: UIViewControllerRepresentable {
    let urls: [URL]
    var onCompletion: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Bool) -> Void

        init(onCompletion: @escaping (Bool) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(false)
        }
    }
}

// UIKit may request share payloads from an NSItemProvider worker queue. These
// sources only read immutable data; they must not inherit MainActor isolation.
nonisolated final class ImageActivityItemSource: NSObject, UIActivityItemSource, Sendable {
    private let image: UIImage
    private let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

nonisolated final class URLActivityItemSource: NSObject, UIActivityItemSource, Sendable {
    private let url: URL
    private let title: String
    private let subject: String?
    private let previewImage: UIImage?

    init(url: URL, title: String, subject: String? = nil, previewImage: UIImage?) {
        self.url = url
        self.title = title
        self.subject = subject
        self.previewImage = previewImage
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject ?? title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url

        if let previewImage {
            metadata.imageProvider = NSItemProvider(object: previewImage)
            metadata.iconProvider = NSItemProvider(object: previewImage)
        }
        return metadata
    }
}

enum StillPhotoShareItemFactory {
    static func makeItem(
        sourceURL: URL,
        title: String,
        subject: String?,
        fileTitle: String
    ) throws -> Any {
        let titledURL = try copyShareURL(sourceURL, title: fileTitle)
        return URLActivityItemSource(
            url: titledURL,
            title: title,
            subject: subject,
            previewImage: previewImage(from: titledURL)
        )
    }

    private static func copyShareURL(_ sourceURL: URL, title: String) throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "heic" : sourceURL.pathExtension
        let fileName = "\(sanitizedShareFileName(title)).\(fileExtension)"
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProgressShareItems",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func sanitizedShareFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = name.components(separatedBy: invalidCharacters)
        let cleanedName = components
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedName.isEmpty ? "Progress Photo" : cleanedName
    }

    private static func previewImage(from url: URL) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: thumbnail)
    }
}

nonisolated final class HEICDataActivityItemSource: NSObject, UIActivityItemSource, Sendable {
    private let data: Data
    private let title: String
    private let previewImage: UIImage?

    init(data: Data, title: String, previewImage: UIImage?) {
        self.data = data
        self.title = title
        self.previewImage = previewImage
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.heic.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let previewImage {
            metadata.imageProvider = NSItemProvider(object: previewImage)
            metadata.iconProvider = NSItemProvider(object: previewImage)
        }
        return metadata
    }
}
