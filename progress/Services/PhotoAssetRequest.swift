import Foundation
import Synchronization

/// Completion, network loss, timeout, and cancellation may race. Only the first
/// result resumes the caller, including when it arrives before value() is awaited.
nonisolated final class PhotoAssetRequest<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var cancellation: (@Sendable () -> Void)?
        var isCancelled = false
    }
    private let state = Mutex(State())

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Value, any Error>? = state.withLock { state in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return Optional<CheckedContinuation<Value, any Error>>.none }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func setCancellationAction(_ action: @escaping @Sendable () -> Void) {
        let alreadyCancelled = state.withLock { state in
            if state.isCancelled { return true }
            state.cancellation = action
            return false
        }
        if alreadyCancelled { action() }
    }

    func cancel(throwing error: any Error) {
        finish(.failure(error))
        cancelUnderlyingWork()
    }

    func cancelUnderlyingWork() {
        let action = state.withLock { state in
            state.isCancelled = true
            let action = state.cancellation
            state.cancellation = nil
            return action
        }
        action?()
    }
}
