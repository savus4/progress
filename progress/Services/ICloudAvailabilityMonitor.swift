import CloudKit
import Combine
import Foundation
import OSLog

@MainActor
final class ICloudAvailabilityMonitor: ObservableObject {
    static let shared = ICloudAvailabilityMonitor()
    nonisolated static let availabilityDidChangeNotification = Notification.Name("ICloudAvailabilityMonitor.availabilityDidChange")

    enum State: Equatable {
        case checking
        case available
        case unavailable(String)
    }

    @Published private(set) var state: State = .checking {
        didSet {
            guard oldValue != state else { return }
            if case .unavailable = state {
                CloudKitService.shared.markStagedAssetsIncludedInBackup()
            }
            NotificationCenter.default.post(name: Self.availabilityDidChangeNotification, object: nil)
        }
    }

    var isAvailableForCloudOperations: Bool {
        if case .unavailable = state {
            return false
        }
        return true
    }

    var isLocalModeActive: Bool {
        !isAvailableForCloudOperations
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = state {
            return reason
        }
        return nil
    }

    private let container: CKContainer
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "ICloudAvailability")
    private var accountObserver: NSObjectProtocol?
    private var testingOverrideState: State?

    private init(container: CKContainer = .default()) {
        self.container = container
        accountObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task<Void, Never> { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
        }

        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    isolated deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    func refresh() async {
        if let testingOverrideState {
            state = testingOverrideState
            return
        }

        state = .checking
        let (accountStatus, error) = await accountStatus()

        if let error {
            logger.error("account-status-error \(Self.describe(error), privacy: .public)")
            if Self.isUnavailableCloudKitError(error) {
                state = .unavailable("iCloud is turned off for this device or app.")
            } else {
                state = .unavailable("iCloud status is unavailable right now.")
            }
            return
        }

        switch accountStatus {
        case .available:
            state = .available
        case .noAccount:
            state = .unavailable("iCloud is not signed in on this device.")
        case .restricted:
            state = .unavailable("iCloud is restricted on this device.")
        case .couldNotDetermine:
            state = .unavailable("iCloud status is unavailable right now.")
        case .temporarilyUnavailable:
            state = .unavailable("iCloud is temporarily unavailable.")
        @unknown default:
            state = .unavailable("iCloud status is unavailable right now.")
        }
    }

    func recordCloudKitError(_ error: Error) {
        guard Self.isUnavailableCloudKitError(error) else { return }
        state = .unavailable("iCloud is turned off for this device or app.")
    }

    func setStateForTesting(_ state: State?) {
        testingOverrideState = state
        if let state {
            self.state = state
        }
    }

    nonisolated static func isUnavailableCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == CKError.errorDomain,
           let ckErrorCode = CKError.Code(rawValue: nsError.code) {
            switch ckErrorCode {
            case .notAuthenticated, .permissionFailure, .accountTemporarilyUnavailable:
                return true
            default:
                break
            }
        }

        if nsError.domain == NSCocoaErrorDomain, nsError.code == 134400 {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isUnavailableCloudKitError(underlyingError) {
            return true
        }

        if let detailedErrors = nsError.userInfo["NSDetailedErrors"] as? [Error] {
            return detailedErrors.contains(where: isUnavailableCloudKitError)
        }

        return false
    }

    private func accountStatus() async -> (CKAccountStatus, Error?) {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                continuation.resume(returning: (status, error))
            }
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError(\(ckError.code.rawValue)): \(ckError.localizedDescription)"
        }
        return error.localizedDescription
    }
}
