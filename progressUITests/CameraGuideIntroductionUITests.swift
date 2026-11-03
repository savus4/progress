import XCTest

final class CameraGuideIntroductionUITests: XCTestCase {
    @MainActor
    func testFirstPreviewShowsTimedLabelsAndGridLongPressReplaysThem() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local"
        app.launchEnvironment["UI_TEST_RESET_CAMERA_GUIDE_INTRODUCTION"] = "1"
        app.launch()

        let openCamera = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(openCamera.waitForExistence(timeout: 10))
        openCamera.tap()
        dismissMockPreview(in: app)

        let eyes = app.descendants(matching: .any)["Eye Alignment Guide"].firstMatch
        let mouth = app.descendants(matching: .any)["Mouth Alignment Guide"].firstMatch
        let guides = app.buttons["experimentalCameraGuidesButton"]
        XCTAssertTrue(eyes.waitForExistence(timeout: 5))
        XCTAssertTrue(mouth.exists)
        XCTAssertTrue(guides.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Camera alignment guide introduction"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(eyes.waitForNonExistence(timeout: 12))
        XCTAssertFalse(mouth.exists)

        // First-use state survives a fresh camera presentation.
        app.buttons["experimentalCameraCloseButton"].tap()
        openCamera.tap()
        dismissMockPreview(in: app)
        XCTAssertFalse(eyes.exists)
        XCTAssertFalse(mouth.exists)

        // Save a photo so the grid's floating Capture button is available.
        app.buttons["experimentalCameraShutter"].tap()
        let done = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        let gridCapture = app.buttons["gridCaptureButton"]
        XCTAssertTrue(gridCapture.waitForExistence(timeout: 5))
        gridCapture.tap()
        dismissMockPreview(in: app)
        XCTAssertFalse(eyes.exists)

        // Replay may temporarily reveal hidden guides, but must preserve the preference.
        guides.tap()
        let visibility = app.buttons["experimentalCameraGuideVisibilityButton"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 5))
        if visibility.value as? String == "Visible" { visibility.tap() }
        app.buttons["Done Editing Guides"].tap()
        app.buttons["experimentalCameraCloseButton"].tap()

        gridCapture.press(forDuration: 0.8)
        dismissMockPreview(in: app)
        XCTAssertTrue(eyes.waitForExistence(timeout: 5))
        XCTAssertTrue(mouth.exists)
        guides.tap()
        XCTAssertTrue(app.buttons["Cancel Guide Changes"].waitForExistence(timeout: 5))
        app.buttons["Cancel Guide Changes"].tap()
        XCTAssertTrue(eyes.waitForNonExistence(timeout: 5))
        guides.tap()
        XCTAssertTrue(visibility.waitForExistence(timeout: 5))
        XCTAssertEqual(visibility.value as? String, "Hidden")
    }

    @MainActor
    private func dismissMockPreview(in app: XCUIApplication) {
        let retake = app.buttons["capturePreviewRetakeButton"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(retake.waitForNonExistence(timeout: 5))
    }
}
