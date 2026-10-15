import CloudKit
import Foundation

nonisolated enum PhotoDownloadFailure: Sendable, Equatable {
    case offline
    case timedOut
    case unavailable

    init(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue: self = .offline
            case URLError.timedOut.rawValue: self = .timedOut
            default: self = .unavailable
            }
        } else if error.domain == CKError.errorDomain,
                  error.code == CKError.networkUnavailable.rawValue || error.code == CKError.networkFailure.rawValue {
            self = .offline
        } else {
            self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .offline: "You’re Offline"
        case .timedOut: "Download Timed Out"
        case .unavailable: "Couldn’t Download Photo"
        }
    }

    func message(isLiveMotion: Bool) -> String {
        switch self {
        case .offline: isLiveMotion ? "Live Photo motion isn’t saved on this device." : "This photo isn’t saved on this device."
        case .timedOut: "Check your connection and try again."
        case .unavailable: isLiveMotion ? "Live Photo motion couldn’t be loaded." : "Try downloading again."
        }
    }
}
