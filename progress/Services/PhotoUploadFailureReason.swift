import CloudKit
import Foundation

nonisolated enum PhotoUploadFailureReason: String, Codable, Sendable {
    case iCloudStorageFull
    case missingUploadAsset

    static func classify(_ error: any Error) -> Self? {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.quotaExceeded.rawValue { return .iCloudStorageFull }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error
        let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] ?? [:]
        let detailedErrors = nsError.userInfo["NSDetailedErrors"] as? [any Error] ?? []
        let nestedErrors = [underlying].compactMap { $0 } + Array(partialErrors.values) + detailedErrors
        let nestedReasons = nestedErrors.compactMap(classify)
        if nestedReasons.contains(.iCloudStorageFull) { return .iCloudStorageFull }
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.assetFileNotFound.rawValue { return .missingUploadAsset }
        if (error as? CloudKitError) == .assetNotFound { return .missingUploadAsset }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileReadNoSuchFile.rawValue { return .missingUploadAsset }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 { return .missingUploadAsset }
        if nestedReasons.contains(.missingUploadAsset) { return .missingUploadAsset }
        return nil
    }

    static func isLegacyMissingAssetError(_ message: String?) -> Bool {
        message?.hasPrefix("CKError(\(CKError.assetFileNotFound.rawValue)):") == true
    }
}
