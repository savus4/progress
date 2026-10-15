import Foundation

nonisolated struct PhotoStorageLimitSteps: Sendable {
    private static let megabyte: Int64 = 1_000_000
    private static let gigabyte: Int64 = 1_000_000_000
    let maximumIndex: Int

    init(availableBytes: Int64) {
        let available = max(PhotoOfflineSettings.minimumLimitBytes, availableBytes)
        if available < Self.gigabyte {
            maximumIndex = Int(available / (100 * Self.megabyte) - 1)
        } else if available < 100 * Self.gigabyte {
            maximumIndex = 9 + Int((available - Self.gigabyte) / Self.gigabyte)
        } else {
            maximumIndex = 108 + Int((available - 100 * Self.gigabyte) / (5 * Self.gigabyte))
        }
    }

    var maximumBytes: Int64 { bytes(at: maximumIndex) }

    func bytes(at index: Int) -> Int64 {
        let index = min(maximumIndex, max(0, index))
        if index <= 9 { return Int64(index + 1) * 100 * Self.megabyte }
        if index <= 108 { return Self.gigabyte + Int64(index - 9) * Self.gigabyte }
        return 100 * Self.gigabyte + Int64(index - 108) * 5 * Self.gigabyte
    }

    func index(for bytes: Double) -> Int {
        guard bytes.isFinite else { return bytes > 0 ? maximumIndex : 0 }
        let bytes = min(Double(maximumBytes), max(Double(PhotoOfflineSettings.minimumLimitBytes), bytes))
        let position: Double
        if bytes < Double(Self.gigabyte) {
            position = bytes / Double(100 * Self.megabyte) - 1
        } else if bytes < Double(100 * Self.gigabyte) {
            position = 9 + (bytes - Double(Self.gigabyte)) / Double(Self.gigabyte)
        } else {
            position = 108 + (bytes - Double(100 * Self.gigabyte)) / Double(5 * Self.gigabyte)
        }
        return min(maximumIndex, max(0, Int(position.rounded())))
    }

    func snappedBytes(_ bytes: Double) -> Int64 { self.bytes(at: index(for: bytes)) }
}
