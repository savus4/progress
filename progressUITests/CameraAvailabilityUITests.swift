import XCTest

final class CameraAvailabilityUITests: XCTestCase {
    @MainActor
    func testUnavailableSimulatorCameraCanBeClosedAndReopened() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES", "UI_TEST_IN_MEMORY_STORE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["STORAGE_TEST_HOST"] = "0"
        app.resetAuthorizationStatus(for: .camera)
        app.resetAuthorizationStatus(for: .location)

        addUIInterruptionMonitor(withDescription: "Camera and location permissions") { alert in
            for title in ["Allow", "Allow While Using App", "OK"] {
                if alert.buttons[title].exists {
                    alert.buttons[title].tap()
                    return true
                }
            }
            return false
        }
        app.launch()

        for _ in 0..<2 {
            let openCamera = app.buttons["emptyStateCaptureButton"]
            XCTAssertTrue(openCamera.waitForExistence(timeout: 10))
            openCamera.tap()

            let shutter = app.buttons["experimentalCameraShutter"]
            XCTAssertTrue(shutter.waitForExistence(timeout: 10))
            // Trigger the interruption monitor if this is the first permission request.
            app.tap()
            let unavailableAlert = app.alerts["Unable to Take Photo"]
            XCTAssertTrue(unavailableAlert.waitForExistence(timeout: 10))
            XCTAssertTrue(unavailableAlert.staticTexts[
                "Camera capture isn’t available in the simulator. Use an iPhone to take a photo."
            ].exists)
            unavailableAlert.buttons["OK"].tap()

            XCTAssertFalse(shutter.isEnabled)
            let closeCamera = app.buttons["experimentalCameraCloseButton"]
            XCTAssertTrue(closeCamera.isEnabled)
            closeCamera.tap()
            XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))
        }
    }
}
