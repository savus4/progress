import Foundation

enum PhotoAssetDownload {
    static func run<Value: Sendable>(
        network: PhotoNetworkMonitor?,
        timeout: Duration = .seconds(30),
        start: @MainActor (PhotoAssetRequest<Value>) -> (@Sendable () -> Void)
    ) async throws -> Value {
        try await network?.requireConnection()
        try Task.checkCancellation()
        let request = PhotoAssetRequest<Value>()
        let observer = network?.onOffline { request.cancel(throwing: URLError(.notConnectedToInternet)) }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            request.cancel(throwing: URLError(.timedOut))
        }
        defer {
            deadline.cancel()
            if let observer { network?.removeOfflineHandler(observer) }
            request.cancelUnderlyingWork()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            request.setCancellationAction(start(request))
            return try await request.value()
        } onCancel: {
            request.cancel(throwing: CancellationError())
        }
    }
}
