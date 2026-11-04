import XCTest

final class HirsModeProUITests: XCTestCase {
    @MainActor
    func testProEnablesHirsAndSaveRetryKeepsMirroredPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local"
        app.launchEnvironment["UI_TEST_FAIL_FIRST_CAPTURE_SAVE"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let hirs = app.switches["hirsModeToggle"]
        let pro = app.switches["hirsModeProToggle"]
        for _ in 0..<5 where !pro.isHittable { app.swipeUp() }
        XCTAssertTrue(pro.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(pro.frame.minY, hirs.frame.minY)
        XCTAssertLessThanOrEqual(pro.frame.minY - hirs.frame.maxY, 16)
        if hirs.value as? String == "1" {
            hirs.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(hirs.value as? String, "0")
        XCTAssertEqual(pro.value as? String, "0")
        if pro.value as? String != "1" {
            pro.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(hirs.value as? String, "1")
        XCTAssertEqual(pro.value as? String, "1")
        let description = app.staticTexts["hirsModeDescription"]
        XCTAssertTrue(description.exists)
        XCTAssertEqual(description.label, "Hirs Mode mirrors previews. Pro mirrors all photos and exports.")
        XCTAssertGreaterThanOrEqual(description.frame.minY, pro.frame.maxY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Dependent Hirs Mode settings with shared description"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close"].tap()

        app.buttons["emptyStateCaptureButton"].tap()
        let preview = app.otherElements["capturePreviewOverlay"]
        let done = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Mirrored")
        done.tap()
        let error = app.alerts["Unable to Save Photo"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        error.buttons["OK"].tap()
        XCTAssertEqual(preview.value as? String, "Mirrored")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.cells.matching(identifier: "photoGridItem").count, 1)
        let photo = app.cells.matching(identifier: "photoGridItem").firstMatch
        let detail = app.descendants(matching: .any)["photoDetailImage"].firstMatch
        photo.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String, "Mirrored")
        app.buttons["Back"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))

        settings.tap()
        for _ in 0..<5 where !pro.isHittable { app.swipeUp() }
        XCTAssertEqual(pro.value as? String, "1")
        XCTAssertEqual(hirs.value as? String, "1")
        pro.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(pro.value as? String, "0")
        XCTAssertEqual(hirs.value as? String, "1")
        app.buttons["Close"].tap()
        photo.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String, "Original")
        app.buttons["Back"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        settings.tap()
        for _ in 0..<5 where !pro.isHittable { app.swipeUp() }
        pro.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        hirs.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(hirs.value as? String, "0")
        XCTAssertEqual(pro.value as? String, "0")
        app.buttons["Close"].tap()
        app.buttons["gridCaptureButton"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Original")
    }
}
