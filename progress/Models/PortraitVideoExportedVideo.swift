import Foundation

/// Owns the generated file until it is saved or explicitly discarded.
struct PortraitVideoExportedVideo {
    var url: URL?

    @discardableResult
    mutating func filesExporterDidComplete(didExport: Bool) -> Bool {
        guard didExport else { return false }
        discard()
        return true
    }

    mutating func discard() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        self.url = nil
    }
}
