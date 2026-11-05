import Foundation
import Synchronization

/// Captures CloudKit's reported download progress without logging every callback.
nonisolated final class CloudKitAssetFetchProgress: Sendable {
    private struct State {
        var firstCallbackMilliseconds: Int64?
        var firstPositiveMilliseconds: Int64?
        var lastPercent = -1
        var reportedQuarter = -1
        var lastReportMilliseconds: Int64 = 0
        var finished = false
    }

    private let state = Mutex(State())
    private let trace: VideoExportDiagnostics.Span?

    init(trace: VideoExportDiagnostics.Span?) {
        self.trace = trace
    }

    /// Marks submission separately from time spent waiting to join a batch.
    func submitted(operationID: String, recordCount: Int) {
        guard let trace else { return }
        trace.event("submitted", details: "operation=\(operationID) record_count=\(recordCount) elapsed_ms=\(VideoExportDiagnostics.milliseconds(since: trace.startedAt))")
    }

    /// Emits the first callback, first positive progress, and quarter milestones.
    func record(_ fraction: Double) {
        guard let trace, fraction.isFinite else { return }
        let fraction = min(1, max(0, fraction))
        let percent = Int(fraction * 100)
        let elapsed = VideoExportDiagnostics.milliseconds(since: trace.startedAt)
        let details: String? = state.withLock { state in
            guard !state.finished else { return nil }
            let firstCallback = state.firstCallbackMilliseconds == nil
            if firstCallback { state.firstCallbackMilliseconds = elapsed }
            let firstPositive = fraction > 0 && state.firstPositiveMilliseconds == nil
            if firstPositive { state.firstPositiveMilliseconds = elapsed }
            state.lastPercent = max(state.lastPercent, percent)
            let quarter = Int(fraction * 4)
            guard firstCallback || firstPositive || quarter > state.reportedQuarter else { return nil }
            let gap = elapsed - state.lastReportMilliseconds
            state.lastReportMilliseconds = elapsed
            state.reportedQuarter = max(state.reportedQuarter, quarter)
            return "percent=\(percent) first_positive=\(firstPositive) elapsed_ms=\(elapsed) since_previous_report_ms=\(gap)"
        }
        if let details { trace.event("progress", details: details) }
    }

    /// Records absent progress as -1, including on timeout or cancellation.
    func finish() {
        guard let trace else { return }
        let details: String? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            return "first_callback_ms=\(state.firstCallbackMilliseconds ?? -1) first_positive_ms=\(state.firstPositiveMilliseconds ?? -1) last_percent=\(state.lastPercent) elapsed_ms=\(VideoExportDiagnostics.milliseconds(since: trace.startedAt))"
        }
        if let details { trace.event("progress-summary", details: details) }
    }
}
