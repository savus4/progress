import XCTest

final class CameraReferencePhotoUITests: XCTestCase {
    @MainActor
    func testReferenceIsUnavailableWithoutPhotosAndPersistsIndependentlyOfGuides() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local"
        app.launch()

        let openCamera = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(openCamera.waitForExistence(timeout: 10))
        openCamera.tap()
        dismissMockPreview(in: app)

        let editGuides = app.buttons["Edit Alignment Guides"]
        XCTAssertTrue(editGuides.waitForExistence(timeout: 5))
        editGuides.tap()
        let referenceToggle = app.descendants(matching: .any)["experimentalCameraReferencePhotoToggle"].firstMatch
        XCTAssertTrue(referenceToggle.waitForExistence(timeout: 5))
        XCTAssertFalse(referenceToggle.isEnabled)
        app.buttons["Cancel Guide Changes"].tap()

        app.buttons["experimentalCameraShutter"].tap()
        let save = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))

        let gridCapture = app.buttons["gridCaptureButton"]
        XCTAssertTrue(gridCapture.waitForExistence(timeout: 5))
        gridCapture.tap()
        dismissMockPreview(in: app)
        editGuides.tap()
        XCTAssertTrue(referenceToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(referenceToggle.isEnabled)

        let referenceImage = app.images["experimentalCameraReferencePhotoOverlay"]
        if referenceToggle.value as? String == "1" { referenceToggle.tap() }
        referenceToggle.tap()
        XCTAssertTrue(referenceImage.waitForExistence(timeout: 5))
        let guideVisibility = app.buttons["experimentalCameraGuideVisibilityButton"]
        if guideVisibility.value as? String == "Visible" { guideVisibility.tap() }
        app.buttons["Done Editing Guides"].tap()
        XCTAssertTrue(referenceImage.exists)
        XCTAssertTrue(editGuides.exists)

        editGuides.tap()
        referenceToggle.tap()
        XCTAssertTrue(referenceImage.waitForNonExistence(timeout: 5))
        app.buttons["Cancel Guide Changes"].tap()
        XCTAssertTrue(referenceImage.waitForExistence(timeout: 5))

        app.buttons["experimentalCameraCloseButton"].tap()
        gridCapture.tap()
        dismissMockPreview(in: app)
        XCTAssertTrue(referenceImage.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Previous photo reference with guides hidden"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        editGuides.tap()
        referenceToggle.tap()
        app.buttons["Done Editing Guides"].tap()
        XCTAssertTrue(referenceImage.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func dismissMockPreview(in app: XCUIApplication) {
        let retake = app.buttons["capturePreviewRetakeButton"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(retake.waitForNonExistence(timeout: 5))
    }
}
