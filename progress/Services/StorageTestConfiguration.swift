import Foundation

nonisolated enum StorageTestConfiguration {
    static var isIsolatedHost: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["STORAGE_TEST_HOST"] == "1"
        #else
        false
        #endif
    }
}
