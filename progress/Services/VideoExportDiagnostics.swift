import CloudKit
import CryptoKit
import Foundation
import os

/// Notice-level messages are enabled in normal builds and can be captured from
/// the phone in Console or Xcode. Task-local scope excludes unrelated sync work.
nonisolated enum VideoExportDiagnostics {
    @TaskLocal static var runID: String?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "progress",
        category: "VideoExport"
    )

    struct Span: Sendable {
        let runID: String
        let id: String
        let name: String
        let startedAt: ContinuousClock.Instant

        func event(_ event: String, details: String = "", error: (any Error)? = nil) {
            VideoExportDiagnostics.write(
                runID: runID, details: "span=\(id) event=\(name).\(event) \(details)", error: error
            )
        }

        func end(details: String = "") {
            event("end", details: "elapsed_ms=\(VideoExportDiagnostics.milliseconds(since: startedAt)) \(details)")
        }
    }

    static func begin(_ name: String, details: String = "") -> Span? {
        guard let runID else { return nil }
        let span = Span(runID: runID, id: String(UUID().uuidString.prefix(8)), name: name, startedAt: .now)
        span.event("begin", details: details)
        return span
    }

    static func event(_ name: String, details: String = "", error: (any Error)? = nil) {
        guard let runID else { return }
        write(runID: runID, details: "event=\(name) \(details)", error: error)
    }

    static func assetTag(_ assetName: String) -> String {
        // Correlate prefetches and photo processing without logging filenames.
        guard runID != nil else { return "" }
        return SHA256.hash(data: Data(assetName.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func assetRead(_ assetName: String, source: String, url: URL) {
        guard runID != nil else { return }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        event("asset.read", details: "asset=\(assetTag(assetName)) source=\(source) bytes=\(bytes)")
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: .now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    static var systemState: String {
        let process = ProcessInfo.processInfo
        return "low_power=\(process.isLowPowerModeEnabled) thermal=\(process.thermalState.rawValue)"
    }

    private static func write(runID: String, details: String, error: (any Error)?) {
        let message = "[VideoExport] run=\(runID) \(details)"
        if let error {
            logger.error("\(message, privacy: .public) error={\(errorDetails(error), privacy: .public)}")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
    }

    private static func errorDetails(_ error: any Error, depth: Int = 0) -> String {
        let nsError = error as NSError
        var details = "domain=\(nsError.domain) code=\(nsError.code)"
        if let ckError = CloudKitErrorBridge.from(error) {
            switch ckError.code {
            case .requestRateLimited: details += " cloudkit=requestRateLimited"
            case .serviceUnavailable: details += " cloudkit=serviceUnavailable"
            case .zoneBusy: details += " cloudkit=zoneBusy"
            case .partialFailure: details += " cloudkit=partialFailure"
            default: break
            }
            if let retryAfter = ckError.retryAfterSeconds {
                details += " retry_after_s=\(retryAfter)"
            }
        }
        if let throttle = nsError.userInfo["CKErrorShouldThrottleClient"] as? NSNumber {
            details += " should_throttle=\(throttle.boolValue)"
        }
        if let requestID = nsError.userInfo["RequestUUID"] {
            details += " request_id=\(requestID)"
        }
        // MapKit's GEOErrorDomain may carry its throttle window here rather
        // than exposing a CloudKit retry-after value.
        for key in ["timeUntilReset", "maxRequests", "windowSize", "requestKind"] {
            if let value = nsError.userInfo[key] as? NSNumber {
                details += " \(key)=\(value)"
            }
        }
        if let windows = nsError.userInfo["details"] as? [[String: Any]] {
            for window in windows.prefix(3) {
                for key in ["timeUntilReset", "maxRequests", "windowSize"] {
                    if let value = window[key] as? NSNumber {
                        details += " \(key)=\(value)"
                    }
                }
            }
        }
        // Keep underlying and partial CloudKit errors, but exclude record IDs,
        // descriptions, coordinates, and file paths from public log messages.
        if depth < 3 {
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
                details += " underlying={\(errorDetails(underlying, depth: depth + 1))}"
            }
            if let partials = CloudKitErrorBridge.from(error)?.partialErrorsByItemID {
                details += " partial_count=\(partials.count)"
                for partial in partials.values.prefix(5) {
                    details += " partial={\(errorDetails(partial, depth: depth + 1))}"
                }
            }
        }
        return details
    }
}
