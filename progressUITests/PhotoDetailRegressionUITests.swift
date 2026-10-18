import XCTest

final class PhotoDetailRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHiddenPhotoCannotBeFavoritedAndCanBeUnhiddenFromSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES", "UI_TEST_IN_MEMORY_STORE", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_MOCK_CAPTURE"] = "1"
        app.launch()

        let captureButton = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        captureButton.tap()
        let doneButton = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(doneButton.waitForNonExistence(timeout: 5))

        let gridItem = app.cells["photoGridItem"].firstMatch
        XCTAssertTrue(gridItem.waitForExistence(timeout: 10))
        gridItem.tap()
        let favoriteButton = app.buttons["Favorite"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5))
        favoriteButton.tap()
        XCTAssertTrue(app.buttons["Remove Favorite"].waitForExistence(timeout: 5))
        app.buttons["More Photo Actions"].tap()
        app.buttons["Hide from Video"].tap()
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5))
        XCTAssertTrue(favoriteButton.isEnabled)
        XCTAssertFalse(app.buttons["Favorite Live Photo"].isEnabled)
        let favoriteAttemptedAt = Date()
        favoriteButton.tap()
        let notice = app.descendants(matching: .any)["hiddenPhotoFavoriteNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 2))
        XCTAssertTrue(notice.label.contains("hidden from videos"))
        let noticeScreenshot = XCTAttachment(screenshot: app.screenshot())
        noticeScreenshot.name = "Hidden photo favorite explanation"
        noticeScreenshot.lifetime = .keepAlways
        add(noticeScreenshot)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 7))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(favoriteAttemptedAt), 4.5)
        XCTAssertFalse(app.buttons["Remove Favorite"].exists)

        favoriteButton.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 2))

        app.buttons["More Photo Actions"].tap()
        XCTAssertTrue(app.buttons["Unhide from Video"].waitForExistence(timeout: 5))
        app.buttons["Unhide from Video"].tap()
        XCTAssertTrue(favoriteButton.isEnabled)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 2))
        app.buttons["More Photo Actions"].tap()
        app.buttons["Hide from Video"].tap()
        app.buttons["Back"].tap()

        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
        XCTAssertEqual(gridItem.value as? String, "Hidden from video")
        let filterButton = app.buttons["gridFilterButton"]
        filterButton.tap()
        app.buttons["Hidden"].tap()
        XCTAssertEqual(filterButton.value as? String, "Hidden")
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
        app.buttons["Select"].tap()
        gridItem.tap()
        XCTAssertFalse(app.buttons["Favorite Selected Photos"].isEnabled)
        XCTAssertFalse(app.buttons["Favorite Live Photo"].isEnabled)
        app.buttons["More Selection Actions"].tap()
        app.buttons["Unhide Selected from Video (1)"].tap()
        XCTAssertTrue(app.staticTexts["No Hidden Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(filterButton.isHittable)
        filterButton.tap()
        app.buttons["All Photos"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))

        app.buttons["Select"].tap()
        gridItem.tap()
        XCTAssertTrue(app.buttons["Favorite Selected Photos"].isEnabled)
        app.buttons["More Selection Actions"].tap()
        app.buttons["Hide Selected from Video (1)"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertEqual(gridItem.value as? String, "Hidden from video")
    }

    @MainActor
    func testRemovingLastHeartedPhotoStillAllowsClosingDetail() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchArguments += ["UI_TEST_IN_MEMORY_STORE", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_MOCK_CAPTURE"] = "1"
        app.launch()

        let captureButton = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        captureButton.tap()
        let doneButton = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(doneButton.waitForNonExistence(timeout: 5))

        let gridItem = app.cells["photoGridItem"].firstMatch
        XCTAssertTrue(gridItem.waitForExistence(timeout: 10))
        gridItem.tap()
        let favoriteButton = app.buttons["Favorite"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5))
        favoriteButton.tap()
        XCTAssertTrue(app.buttons["Remove Favorite"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Back"].waitForNonExistence(timeout: 5))

        let filterButton = app.buttons["gridFilterButton"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        app.buttons["Hearted"].tap()
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
        gridItem.tap()

        let removeFavoriteButton = app.buttons["Remove Favorite"]
        XCTAssertTrue(removeFavoriteButton.waitForExistence(timeout: 5))
        removeFavoriteButton.tap()
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5))
        app.buttons["Back"].tap()

        XCTAssertTrue(app.buttons["Back"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Hearted Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(filterButton.isHittable)
        filterButton.tap()
        app.buttons["All Photos"].tap()
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
    }
}
