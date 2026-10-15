import CloudKit
import Foundation
import Synchronization
import Testing
@testable import progress

@MainActor
struct PhotoAssetDownloadTests {
    @Test("Offline devices read all local stores, skip remote fetches, and fetch again after reconnecting")
    func offlineReadsAndReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoNetworkTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.heic")
        let readable = root.appendingPathComponent("Readable")
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        let data = Data("photo original".utf8)
        try data.write(to: source)
        try data.write(to: readable.appendingPathComponent("readable.heic"))
        let network = PhotoNetworkMonitor(initialState: .offline, monitorsNetwork: false)
        var downloadCount = 0
        let cloud = CloudKitService(
            stagingDirectoryURL: root.appendingPathComponent("Staging"),
            temporaryReadableAssetsDirectoryURL: readable, legacyAssetDirectoryURLs: [],
            assetURLLoader: { _ in downloadCount += 1; return source },
            networkMonitor: network
        )
        _ = try cloud.stageAssetData(data, named: "staged.heic", includesInBackup: true)
        try await cloud.offlineStore.retain(from: source, named: "offline.heic")
        for name in ["staged.heic", "offline.heic", "readable.heic"] {
            let url = try await cloud.loadAssetURL(named: name)
            #expect(try Data(contentsOf: url) == data)
        }
        do {
            _ = try await cloud.loadAssetURL(named: "remote.heic")
            Issue.record("An offline remote fetch should fail immediately")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        #expect(downloadCount == 0)
        network.update(.connected)
        let fetched = try await cloud.loadAssetURL(named: "remote.heic")
        #expect(try Data(contentsOf: fetched) == data)
        #expect(downloadCount == 1)
    }

    @Test("Losing connectivity stops the request even when the backend never calls its completion")
    func networkLossCancelsPendingRequest() async {
        let network = PhotoNetworkMonitor(initialState: .connected, monitorsNetwork: false)
        let cancellations = Mutex(0)
        do {
            let _: String = try await PhotoAssetDownload.run(network: network) { request in
                network.update(.offline)
                return {
                    cancellations.withLock { $0 += 1 }
                    request.finish(.success("late callback"))
                }
            }
            Issue.record("Network loss should fail the request")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test("A silent backend times out and its operation is cancelled")
    func silentRequestTimesOut() async {
        let cancellations = Mutex(0)
        do {
            let _: Int = try await PhotoAssetDownload.run(network: nil, timeout: .milliseconds(10)) { _ in
                { cancellations.withLock { $0 += 1 } }
            }
            Issue.record("A silent backend must not leave the caller waiting")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test("Leaving the photo cancels immediately; late backend callbacks cannot replace cancellation")
    func callerCancellation() async throws {
        let started = PhotoAssetRequest<PhotoAssetRequest<String>>()
        let cancellations = Mutex(0)
        let work = Task {
            try await PhotoAssetDownload.run(network: nil) { (request: PhotoAssetRequest<String>) in
                started.finish(.success(request))
                return { cancellations.withLock { $0 += 1 } }
            }
        }
        let request = try await started.value()
        work.cancel()
        request.finish(.success("late callback"))
        do {
            _ = try await work.value
            Issue.record("The cancelled photo request should throw CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test("Only the first of per-record and whole-operation callbacks resumes the caller")
    func competingCompletions() async throws {
        let value: Int = try await PhotoAssetDownload.run(network: nil) { request in
            request.finish(.success(42))
            request.finish(.failure(URLError(.networkConnectionLost)))
            return {}
        }
        #expect(value == 42)
    }

    @Test("Metadata preserves partial results and ignores completion after cancellation")
    func metadataCompletionRaces() async throws {
        let request = PhotoAssetRequest<[String: Result<PhotoAssetMetadata, any Error>]>()
        let completion = CloudKitAssetMetadataFetchOperation(request)
        let record = CKRecord(recordType: "PhotoAsset")
        record["byteCount"] = NSNumber(value: 4)
        completion.record("available", result: .success(record))
        completion.record("missing", result: .failure(CKError(.unknownItem)))
        completion.finish(.failure(CKError(.networkFailure)))
        let results = try await request.value()
        #expect(try results["available"]?.get().byteCount == 4)
        #expect(results.count == 2)

        let cancelled = PhotoAssetRequest<[String: Result<PhotoAssetMetadata, any Error>]>()
        let late = CloudKitAssetMetadataFetchOperation(cancelled)
        cancelled.cancel(throwing: URLError(.timedOut))
        late.record("available", result: .success(record))
        late.finish(.success(()))
        do {
            _ = try await cancelled.value()
            Issue.record("Late metadata completion must not replace a timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test("The viewer distinguishes offline, timeout, and missing-original failures")
    func failureMessages() {
        #expect(PhotoDownloadFailure(URLError(.notConnectedToInternet)) == .offline)
        #expect(PhotoDownloadFailure(URLError(.networkConnectionLost)) == .offline)
        #expect(PhotoDownloadFailure(CKError(.networkUnavailable)) == .offline)
        #expect(PhotoDownloadFailure(CKError(.networkFailure)) == .offline)
        #expect(PhotoDownloadFailure(URLError(.timedOut)) == .timedOut)
        #expect(PhotoDownloadFailure(CloudKitError.assetNotFound) == .unavailable)
    }
}
