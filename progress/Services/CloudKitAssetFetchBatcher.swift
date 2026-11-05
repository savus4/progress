import CloudKit
import Foundation
import Synchronization

/// Coalesces compatible original requests while preserving per-record completion
/// and cancellation. The exporter's permit pool bounds total in-flight assets.
@MainActor
final class CloudKitAssetFetchBatcher {
    private let maximumRecordCount: Int
    private let coalescingDelay: Duration
    private let submitOperation: @MainActor (CKFetchRecordsOperation) -> Void
    private var pending: [CloudKitAssetFetchEntry] = []
    private var flushTask: Task<Void, Never>?

    init(
        maximumRecordCount: Int,
        coalescingDelay: Duration = .milliseconds(10),
        submitOperation: @escaping @MainActor (CKFetchRecordsOperation) -> Void
    ) {
        self.maximumRecordCount = max(1, maximumRecordCount)
        self.coalescingDelay = coalescingDelay
        self.submitOperation = submitOperation
    }

    /// Enqueues one record and returns cancellation for only that subscriber.
    func enqueue(
        recordID: CKRecord.ID,
        configuration: CKOperation.Configuration,
        request: PhotoAssetRequest<CKRecord>,
        progress: CloudKitAssetFetchProgress
    ) -> @Sendable () -> Void {
        let entry = CloudKitAssetFetchEntry(
            recordID: recordID, configuration: configuration, request: request, progress: progress
        )
        pending.removeAll { $0.isCancelled }
        pending.append(entry)
        if pending.filter({ $0.matches(entry) }).count >= maximumRecordCount {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self, coalescingDelay] in
                do { try await Task.sleep(for: coalescingDelay) }
                catch { return }
                self?.flush()
            }
        }
        return { entry.cancel() }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll { $0.isCancelled }
        while let first = pending.first {
            let entries = Array(pending.lazy.filter { $0.matches(first) }.prefix(maximumRecordCount))
            let selected = Set(entries.map(\.id))
            pending.removeAll { selected.contains($0.id) }
            submit(entries)
        }
    }

    private func submit(_ entries: [CloudKitAssetFetchEntry]) {
        guard let first = entries.first else { return }
        var seen: Set<CKRecord.ID> = []
        let recordIDs = entries.map(\.recordID).filter { seen.insert($0).inserted }
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.configuration.allowsCellularAccess = first.allowsCellularAccess
        operation.configuration.qualityOfService = first.qualityOfService
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        let trace = VideoExportDiagnostics.begin(
            "cloudkit.batch",
            details: "operation=\(operation.operationID) record_count=\(recordIDs.count) qos=\(first.qualityOfService.rawValue)"
        )
        let completion = CloudKitAssetFetchBatch(entries: entries, operation: operation, trace: trace)
        for entry in entries {
            entry.setCancellationAction { [weak completion, entryID = entry.id] in completion?.cancel(entryID: entryID) }
        }
        guard completion.hasPendingRecords else {
            completion.finish(.failure(CancellationError()))
            return
        }
        operation.perRecordProgressBlock = { id, fraction in completion.progress(recordID: id, fraction: fraction) }
        operation.perRecordResultBlock = { id, result in completion.record(recordID: id, result: result) }
        operation.fetchRecordsResultBlock = { result in completion.finish(result) }
        for entry in entries where !entry.isCancelled {
            entry.progress.submitted(operationID: operation.operationID, recordCount: recordIDs.count)
        }
        submitOperation(operation)
    }

    isolated deinit { flushTask?.cancel() }
}

/// Owns a subscriber's cancellation before and after its operation is submitted.
nonisolated private final class CloudKitAssetFetchEntry: Sendable {
    private struct State {
        var isCancelled = false
        var cancellation: (@Sendable () -> Void)?
    }
    let id = UUID()
    let recordID: CKRecord.ID
    let allowsCellularAccess: Bool
    let qualityOfService: QualityOfService
    let request: PhotoAssetRequest<CKRecord>
    let progress: CloudKitAssetFetchProgress
    private let state = Mutex(State())

    init(recordID: CKRecord.ID, configuration: CKOperation.Configuration,
         request: PhotoAssetRequest<CKRecord>, progress: CloudKitAssetFetchProgress) {
        self.recordID = recordID
        allowsCellularAccess = configuration.allowsCellularAccess
        qualityOfService = configuration.qualityOfService
        self.request = request
        self.progress = progress
    }

    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func matches(_ other: CloudKitAssetFetchEntry) -> Bool {
        allowsCellularAccess == other.allowsCellularAccess && qualityOfService == other.qualityOfService
    }

    func setCancellationAction(_ action: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { state in
            if state.isCancelled { return true }
            state.cancellation = action
            return false
        }
        if cancelled { action() }
    }

    func cancel() {
        let action = state.withLock { state in
            state.isCancelled = true
            let action = state.cancellation
            state.cancellation = nil
            return action
        }
        action?()
    }
}

/// Bridges callbacks on CloudKit's queue without waiting for slower batch peers.
nonisolated private final class CloudKitAssetFetchBatch: Sendable {
    private struct State {
        var entries: [UUID: CloudKitAssetFetchEntry]
        weak var operation: CKFetchRecordsOperation?
        var finished = false
    }
    private let state: Mutex<State>
    private let trace: VideoExportDiagnostics.Span?

    init(entries: [CloudKitAssetFetchEntry], operation: CKFetchRecordsOperation, trace: VideoExportDiagnostics.Span?) {
        state = Mutex(State(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), operation: operation))
        self.trace = trace
    }

    var hasPendingRecords: Bool { state.withLock { !$0.entries.isEmpty } }

    func progress(recordID: CKRecord.ID, fraction: Double) {
        let entries = state.withLock { $0.entries.values.filter { $0.recordID == recordID } }
        for entry in entries { entry.progress.record(fraction) }
    }

    func record(recordID: CKRecord.ID, result: Result<CKRecord, any Error>) {
        let entries = state.withLock { state in
            let entries = state.entries.values.filter { $0.recordID == recordID }
            for entry in entries { state.entries.removeValue(forKey: entry.id) }
            return entries
        }
        for entry in entries {
            entry.progress.finish()
            entry.request.finish(result)
        }
    }

    func cancel(entryID: UUID) {
        let operation = state.withLock { state -> CKFetchRecordsOperation? in
            guard state.entries.removeValue(forKey: entryID) != nil else { return nil }
            return state.entries.isEmpty ? state.operation : nil
        }
        operation?.cancel()
    }

    func finish(_ result: Result<Void, any Error>) {
        let entries: [CloudKitAssetFetchEntry]? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            let entries = Array(state.entries.values)
            state.entries.removeAll()
            return entries
        }
        guard let entries else { return }
        for entry in entries {
            let error: any Error
            switch result {
            case .success: error = CloudKitError.assetNotFound
            case .failure(let failure):
                error = CloudKitErrorBridge.from(failure)?.partialErrorsByItemID?[entry.recordID] ?? failure
            }
            entry.progress.finish()
            entry.request.finish(.failure(error))
        }
        if case .failure(let error) = result { trace?.event("failed", error: error) }
        trace?.end()
    }
}
