import Photos
import Testing
@testable import progress

@MainActor
struct PhotoImportAuthorizationTests {
    @Test("Private import never reads or requests library permission", arguments: [
        PHAuthorizationStatus.notDetermined, .authorized, .limited, .denied, .restricted
    ])
    func privateImportNeedsNoPermission(status: PHAuthorizationStatus) async {
        let result = await PhotoImportAuthorization.authorize(.privatePhotos, status: {
            Issue.record("Private import must not inspect library permission.")
            return status
        }, request: {
            Issue.record("Private import must not request library permission.")
            return .denied
        })
        #expect(result)
    }

    @Test("Photos and album imports require full access", arguments: [PhotoImportMethod.photos, .album])
    func libraryImportRequiresFullAccess(method: PhotoImportMethod) async {
        for status in [PHAuthorizationStatus.authorized, .limited, .denied, .restricted] {
            let result = await PhotoImportAuthorization.authorize(method, status: { status }, request: {
                Issue.record("An existing permission decision must not prompt again.")
                return .authorized
            })
            #expect(result == (status == .authorized))
        }
    }

    @Test("First use waits for full access before continuing", arguments: [PhotoImportMethod.photos, .album])
    func firstUseRequestsPermission(method: PhotoImportMethod) async {
        for response in [PHAuthorizationStatus.authorized, .limited, .denied, .restricted] {
            var requests = 0
            let result = await PhotoImportAuthorization.authorize(method, status: { .notDetermined }, request: {
                requests += 1
                return response
            })
            #expect(requests == 1)
            #expect(result == (response == .authorized))
        }
    }

    @Test("Cancelled preparation does not request access")
    func cancelledPreparation() async {
        let task = Task { @MainActor in
            await PhotoImportAuthorization.authorize(.photos, status: {
                Issue.record("Cancelled preparation must not inspect permission.")
                return .notDetermined
            }, request: {
                Issue.record("Cancelled preparation must not show a permission prompt.")
                return .authorized
            })
        }
        task.cancel()
        #expect(await task.value == false)
    }
}
