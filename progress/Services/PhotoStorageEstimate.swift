import Foundation

nonisolated struct PhotoStorageEstimate: Sendable {
    let photoCount: Int
    let originalBytes: Int64
    let additionalLocalBytes: Int64
    let freeDeviceBytes: Int64
    var libraryCopyBytes: Int64 = 0

    var peakAdditionalDeviceBytes: Int64 {
        let (copies, overflow) = additionalLocalBytes.multipliedReportingOverflow(by: 2)
        let (libraryCopies, libraryOverflow) = libraryCopyBytes.multipliedReportingOverflow(by: 2)
        let (temporary, temporaryOverflow) = copies.addingReportingOverflow(libraryCopies)
        return overflow || libraryOverflow || temporaryOverflow ? .max : temporary
    }

    // Explicit switches use a margin scaled to their working footprint. The
    // background cache retains its separate, more conservative reserve policy.
    var safetyMarginBytes: Int64 {
        let workingBytes = peakAdditionalDeviceBytes
        guard workingBytes > 0 else { return 0 }
        return min(500_000_000, max(50_000_000, workingBytes / 10))
    }

    var requiredDeviceBytes: Int64 {
        let (total, overflow) = peakAdditionalDeviceBytes.addingReportingOverflow(safetyMarginBytes)
        return overflow ? .max : total
    }

    var fitsOnDevice: Bool { freeDeviceBytes >= requiredDeviceBytes }

    func canRetainOriginal(byteCount: Int64, availableBytes: Int64) -> Bool {
        guard byteCount > 0, byteCount <= Int64.max / 2, availableBytes >= safetyMarginBytes else { return false }
        return byteCount * 2 <= availableBytes - safetyMarginBytes
    }

    @concurrent
    static func libraryFootprint(at url: URL) async throws -> Int64 {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(stem) }
        var size: Int64 = 0
        for file in files {
            var children = [file]
            if let enumerator = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [.fileSizeKey]) {
                children += enumerator.allObjects.compactMap { $0 as? URL }
            }
            for child in children {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
            }
        }
        return size
    }
}
