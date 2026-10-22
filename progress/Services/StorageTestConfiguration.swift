import Foundation

nonisolated enum StorageTestConfiguration {
    static var usesEphemeralLibrary: Bool {
        #if DEBUG && targetEnvironment(simulator)
        isIsolatedHost || ProcessInfo.processInfo.environment["UI_TEST_IN_MEMORY_STORE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("UI_TEST_IN_MEMORY_STORE")
        #else
        false
        #endif
    }

    static var isIsolatedHost: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["STORAGE_TEST_HOST"] == "1"
        #else
        false
        #endif
    }
}
