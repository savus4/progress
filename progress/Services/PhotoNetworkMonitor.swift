import Foundation
import Network
import Observation

@MainActor @Observable
final class PhotoNetworkMonitor {
    static let shared = PhotoNetworkMonitor()
    private(set) var state: PhotoNetworkState
    @ObservationIgnored private let monitor: NWPathMonitor?
    @ObservationIgnored private var offlineHandlers: [UUID: @MainActor () -> Void] = [:]

    init(initialState: PhotoNetworkState = .checking, monitorsNetwork: Bool = true) {
        state = initialState
        monitor = monitorsNetwork ? NWPathMonitor() : nil
        monitor?.pathUpdateHandler = { [weak self] path in
            let state: PhotoNetworkState = path.status == .unsatisfied ? .offline : .connected
            Task { @MainActor [weak self] in self?.update(state) }
        }
        monitor?.start(queue: DispatchQueue(label: "progress.photo-network"))
    }

    func update(_ newState: PhotoNetworkState) {
        guard state != newState else { return }
        state = newState
        if newState == .offline {
            for handler in Array(offlineHandlers.values) { handler() }
        }
    }

    func requireConnection() async throws {
        // Give the first path callback a chance to arrive on a cold launch.
        if state == .checking { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if state == .offline { throw URLError(.notConnectedToInternet) }
    }

    func onOffline(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        offlineHandlers[id] = handler
        if state == .offline { handler() }
        return id
    }

    func removeOfflineHandler(_ id: UUID) { offlineHandlers.removeValue(forKey: id) }

    isolated deinit { monitor?.cancel() }
}
