import XCTest

final class CameraCaptureFeedbackUITests: XCTestCase {
    @MainActor
    func testStillCaptureIndicatorStaysInsidePreview() throws {
        try verifyFeedback(livePhoto: false)
    }

    @MainActor
    func testLiveRecordingChangesToProcessingInsidePreview() throws {
        try verifyFeedback(livePhoto: true)
    }

    @MainActor
    private func verifyFeedback(livePhoto: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "-cameraHasSeenGuideIntroduction", "YES",
                               "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local"
        app.launchEnvironment["UI_TEST_CAPTURE_FEEDBACK"] = livePhoto ? "live" : "still"
        app.launch()
        let open = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let shutter = app.buttons["experimentalCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()

        let status = app.descendants(matching: .any)["cameraCaptureStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let expectedTitle = livePhoto ? "Recording Live Photo" : "Taking Photo"
        XCTAssertTrue(status.label.contains(expectedTitle), status.label)
        let preview = app.descendants(matching: .any)["experimentalCameraPreview"].firstMatch
        XCTAssertTrue(preview.exists)
        XCTAssertGreaterThanOrEqual(status.frame.minX, preview.frame.minX + 15)
        XCTAssertLessThanOrEqual(status.frame.maxX, preview.frame.maxX - 15)
        XCTAssertGreaterThan(status.frame.minY, preview.frame.midY)
        let imageHeight = min(preview.frame.height, preview.frame.width * 4 / 3)
        let imageBottom = preview.frame.midY + imageHeight / 2
        XCTAssertEqual(status.frame.maxY, imageBottom - 16, accuracy: 1)
        XCTAssertLessThan(status.frame.maxY, shutter.frame.minY)

        let processing = NSPredicate(format: "label CONTAINS %@", "Processing Capture")
        expectation(for: processing, evaluatedWith: status)
        waitForExpectations(timeout: 4)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = livePhoto ? "Live capture processing inside preview" : "Still capture processing inside preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["capturePreviewDoneButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(status.exists)
    }
}
