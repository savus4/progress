import CloudKit
import Foundation
import Testing
@testable import progress

@MainActor
@Suite("Batched original downloads", .timeLimit(.minutes(1)))
struct CloudKitAssetFetchBatcherTests {
    @Test("Six requests share one operation and an early record is usable before its peers")
    func batchesSixAndDeliversEarly() async throws {
        try await VideoExportDiagnostics.$runID.withValue("batch-callback-test") {
            var operations: [CKFetchRecordsOperation] = []
            let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 6) { operations.append($0) }
            let ids = makeIDs(count: 6)
            let requests = ids.map { enqueue($0, into: batcher) }
            defer { requests.forEach { $0.cancelUnderlyingWork() } }
            #expect(operations.count == 1)
            let operation = try #require(operations.first)
            #expect(operation.recordIDs == ids)
            #expect(operation.configuration.qualityOfService == .userInitiated)
            #expect(operation.configuration.timeoutIntervalForRequest == 15)
            #expect(operation.configuration.timeoutIntervalForResource == 30)
            for fraction in [0.0, 0.001, 0.02, 0.25, 0.5, 0.75, 1.0] {
                operation.perRecordProgressBlock?(ids[0], fraction)
            }
            operation.perRecordResultBlock?(ids[0], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[0])))
            #expect(try await requests[0].value().recordID == ids[0])
            #expect(operation.isCancelled == false)
            // Releasing this completed subscriber must not cancel slower peers.
            requests[0].cancelUnderlyingWork()
            #expect(operation.isCancelled == false)
            for index in 1..<6 {
                operation.perRecordResultBlock?(ids[index], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[index])))
            }
            operation.fetchRecordsResultBlock?(.success(()))
            // Late duplicate completion must not overwrite the delivered record.
            operation.perRecordResultBlock?(ids[0], .failure(CKError(.networkFailure)))
            for (index, request) in requests.enumerated() {
                #expect(try await request.value().recordID == ids[index])
            }
        }
    }

    @Test("Partial batch failures preserve successful peers and per-record error details")
    func partialFailuresPreservePeers() async throws {
        var operations: [CKFetchRecordsOperation] = []
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 3) { operations.append($0) }
        let ids = makeIDs(count: 3)
        let requests = ids.map { enqueue($0, into: batcher) }
        defer { requests.forEach { $0.cancelUnderlyingWork() } }
        let operation = try #require(operations.first)
        operation.perRecordResultBlock?(ids[0], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[0])))
        operation.perRecordResultBlock?(ids[1], .failure(CKError(.unknownItem)))
        // CloudKit reports each record's error before overall completion.
        operation.perRecordResultBlock?(ids[2], .failure(CKError(.networkFailure)))
        operation.fetchRecordsResultBlock?(.failure(CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [ids[1]: CKError(.unknownItem) as NSError, ids[2]: CKError(.networkFailure) as NSError]
        ])))
        #expect(try await requests[0].value().recordID == ids[0])
        for (index, expected) in [(1, CKError.Code.unknownItem), (2, .networkFailure)] {
            do {
                _ = try await requests[index].value()
                Issue.record("The failed record should retain its own error")
            } catch {
                #expect((error as NSError).domain == CKErrorDomain)
                #expect((error as NSError).code == expected.rawValue)
            }
        }
    }

    @Test("One timed-out subscriber does not cancel other records or accept a late success")
    func timeoutLeavesPeersRunning() async throws {
        var operations: [CKFetchRecordsOperation] = []
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 2) { operations.append($0) }
        let ids = makeIDs(count: 2)
        let requests = ids.map { enqueue($0, into: batcher) }
        defer { requests.forEach { $0.cancelUnderlyingWork() } }
        let operation = try #require(operations.first)
        requests[0].cancel(throwing: URLError(.timedOut))
        #expect(operation.isCancelled == false)
        operation.perRecordResultBlock?(ids[0], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[0])))
        operation.perRecordResultBlock?(ids[1], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[1])))
        operation.fetchRecordsResultBlock?(.success(()))
        #expect(try await requests[1].value().recordID == ids[1])
        do {
            _ = try await requests[0].value()
            Issue.record("Late success must not replace the timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test("Cancelling every remaining subscriber cancels their shared CloudKit operation")
    func cancellingAllStopsOperation() async throws {
        var operations: [CKFetchRecordsOperation] = []
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 2) { operations.append($0) }
        let ids = makeIDs(count: 2)
        let requests = ids.map { enqueue($0, into: batcher) }
        let operation = try #require(operations.first)
        requests[0].cancel(throwing: CancellationError())
        #expect(operation.isCancelled == false)
        requests[1].cancel(throwing: CancellationError())
        #expect(operation.isCancelled)
        operation.perRecordResultBlock?(ids[0], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[0])))
        operation.fetchRecordsResultBlock?(.failure(CKError(.operationCancelled)))
        for request in requests {
            await #expect(throws: CancellationError.self) { try await request.value() }
        }
    }

    @Test("A partial batch flushes without waiting for six records and excludes queued cancellations")
    func tailFlushExcludesCancelledRequests() async throws {
        let submitted = PhotoAssetRequest<CKFetchRecordsOperation>()
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 6, coalescingDelay: .milliseconds(1)) {
            submitted.finish(.success($0))
        }
        let ids = makeIDs(count: 2)
        let requests = ids.map { enqueue($0, into: batcher) }
        defer { requests.forEach { $0.cancelUnderlyingWork() } }
        requests[0].cancel(throwing: CancellationError())
        let operation = try await submitted.value()
        #expect(operation.recordIDs == [ids[1]])
        operation.perRecordResultBlock?(ids[1], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[1])))
        operation.fetchRecordsResultBlock?(.success(()))
        #expect(try await requests[1].value().recordID == ids[1])
        await #expect(throws: CancellationError.self) { try await requests[0].value() }
    }

    @Test("Requests with different cellular policies are submitted separately")
    func differentPoliciesStaySeparate() async throws {
        let submitted = PhotoAssetRequest<[CKFetchRecordsOperation]>()
        var operations: [CKFetchRecordsOperation] = []
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 6, coalescingDelay: .milliseconds(1)) {
            operations.append($0)
            if operations.count == 2 { submitted.finish(.success(operations)) }
        }
        let ids = makeIDs(count: 2)
        let requests = [enqueue(ids[0], into: batcher, allowsCellularAccess: false), enqueue(ids[1], into: batcher)]
        defer { requests.forEach { $0.cancelUnderlyingWork() } }
        let submittedOperations = try await submitted.value()
        #expect(submittedOperations.count == 2)
        #expect(submittedOperations[0].configuration.allowsCellularAccess == false)
        #expect(submittedOperations[1].configuration.allowsCellularAccess == true)
        for (index, operation) in submittedOperations.enumerated() {
            #expect(operation.recordIDs == [ids[index]])
            operation.perRecordResultBlock?(ids[index], .success(CKRecord(recordType: "PhotoAsset", recordID: ids[index])))
            operation.fetchRecordsResultBlock?(.success(()))
            #expect(try await requests[index].value().recordID == ids[index])
        }
    }

    @Test("Six CloudKitService cache misses share a batch and return stable original bytes")
    func serviceReadsBatchedOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchedOriginals-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (0..<6).map { "original-\($0).heic" }
        let sources = Dictionary(uniqueKeysWithValues: try names.map { name in
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return (name, url)
        })
        var operationCount = 0
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 6) { operation in
            operationCount += 1
            for id in operation.recordIDs ?? [] {
                guard let source = sources[id.recordName] else {
                    Issue.record("Unexpected original requested")
                    operation.perRecordResultBlock?(id, .failure(CKError(.unknownItem)))
                    continue
                }
                let record = CKRecord(recordType: "PhotoAsset", recordID: id)
                record["fileAsset"] = CKAsset(fileURL: source)
                for fraction in [0.0, 0.1, 0.3, 0.6, 1.0] {
                    operation.perRecordProgressBlock?(id, fraction)
                }
                operation.perRecordResultBlock?(id, .success(record))
            }
            operation.fetchRecordsResultBlock?(.success(()))
        }
        let cloud = CloudKitService(
            stagingDirectoryURL: root.appendingPathComponent("Staged"),
            temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("Readable"),
            legacyAssetDirectoryURLs: [],
            networkMonitor: PhotoNetworkMonitor(initialState: .connected, monitorsNetwork: false),
            storageModeStore: PhotoStorageModeStore(storageURL: root.appendingPathComponent("mode.json"))
        )
        let loaded = try await VideoExportDiagnostics.$runID.withValue("batch-integration-test") {
            try await withThrowingTaskGroup(of: (String, URL).self) { group in
                for name in names {
                    group.addTask {
                        let url = try await cloud.loadAssetURL(
                            named: name, qualityOfService: .userInitiated, fetchBatcher: batcher
                        )
                        return (name, url)
                    }
                }
                var results: [String: URL] = [:]
                for try await (name, url) in group { results[name] = url }
                return results
            }
        }
        #expect(operationCount == 1)
        #expect(loaded.count == 6)
        for name in names {
            let url = try #require(loaded[name])
            #expect(url.deletingLastPathComponent().lastPathComponent == "Readable")
            #expect(try Data(contentsOf: url) == Data(name.utf8))
        }
    }

    @Test("Native NSError callbacks preserve retry-after and partial CloudKit errors")
    func nativeErrorMetadataSurvivesBridging() throws {
        let throttled = NSError(domain: CKErrorDomain, code: CKError.Code.requestRateLimited.rawValue,
                                userInfo: [CKErrorRetryAfterKey: 12.0])
        let ckError = try #require(CloudKitErrorBridge.from(throttled))
        #expect(ckError.code == .requestRateLimited)
        #expect(ckError.retryAfterSeconds == 12)
        let id = try #require(makeIDs(count: 1).first)
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: [id: throttled]])
        let nested = try #require(CloudKitErrorBridge.from(partial)?.partialErrorsByItemID?[id])
        #expect(CloudKitErrorBridge.from(nested)?.retryAfterSeconds == 12)
        #expect(CloudKitErrorBridge.from(URLError(.timedOut)) == nil)
        VideoExportDiagnostics.$runID.withValue("batch-error-bridge-test") {
            VideoExportDiagnostics.event("bridge-check", error: partial)
        }
    }

    @Test("Operation-wide network failure resolves every pending record without callbacks")
    func operationFailureResolvesPendingRecords() async throws {
        var operations: [CKFetchRecordsOperation] = []
        let batcher = CloudKitAssetFetchBatcher(maximumRecordCount: 2) { operations.append($0) }
        let requests = makeIDs(count: 2).map { enqueue($0, into: batcher) }
        defer { requests.forEach { $0.cancelUnderlyingWork() } }
        let operation = try #require(operations.first)
        operation.fetchRecordsResultBlock?(.failure(CKError(.networkFailure)))
        for request in requests {
            do {
                _ = try await request.value()
                Issue.record("Operation failure must resolve the pending record")
            } catch {
                #expect((error as NSError).domain == CKErrorDomain)
                #expect((error as NSError).code == CKError.Code.networkFailure.rawValue)
            }
        }
    }

    private func makeIDs(count: Int) -> [CKRecord.ID] {
        (0..<count).map { _ in CKRecord.ID(recordName: UUID().uuidString) }
    }

    private func enqueue(
        _ recordID: CKRecord.ID,
        into batcher: CloudKitAssetFetchBatcher,
        allowsCellularAccess: Bool = true
    ) -> PhotoAssetRequest<CKRecord> {
        let request = PhotoAssetRequest<CKRecord>()
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.allowsCellularAccess = allowsCellularAccess
        let trace = VideoExportDiagnostics.begin("cloudkit.fetch", details: "asset=\(VideoExportDiagnostics.assetTag(recordID.recordName))")
        request.setCancellationAction(batcher.enqueue(
            recordID: recordID, configuration: configuration, request: request,
            progress: CloudKitAssetFetchProgress(trace: trace)
        ))
        return request
    }
}
