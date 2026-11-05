import CloudKit
import Foundation

/// Preserves CloudKit metadata when an Objective-C callback delivers NSError
/// instead of a Swift CKError value.
nonisolated enum CloudKitErrorBridge {
    static func from(_ error: any Error) -> CKError? {
        if let error = error as? CKError { return error }
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code) else { return nil }
        return CKError(code, userInfo: nsError.userInfo)
    }
}
