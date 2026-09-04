import AVFoundation
import Testing
@testable import progress

struct CameraMicrophonePermissionTests {
    @MainActor
    @Test("Microphone is optional and prompted only for undetermined Live Photo access")
    func authorizationPaths() async {
        for enabled in [false, true] {
            for status in [AVAuthorizationStatus.notDetermined, .authorized, .denied, .restricted] {
                for grantsRequest in [false, true] {
                    var requestCount = 0
                    let result = await CameraMicrophonePermission.authorize(
                        enabled: enabled, status: { status }, request: {
                            requestCount += 1
                            return grantsRequest
                        }
                    )
                    #expect(requestCount == (enabled && status == .notDetermined ? 1 : 0))
                    #expect(result == (enabled && (status == .authorized ||
                        (status == .notDetermined && grantsRequest))))
                }
            }
        }
    }

    @MainActor
    @Test("Cancelled camera preparation does not request microphone permission")
    func cancellation() async {
        var requests = 0
        let task = Task { @MainActor in
            await CameraMicrophonePermission.authorize(
                enabled: true, status: { .notDetermined }, request: {
                    requests += 1
                    return true
                }
            )
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(requests == 0)
    }

    @Test("App includes a microphone purpose string")
    func purposeString() throws {
        let description = try #require(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        #expect(description.contains("Live Photos"))
    }
}
