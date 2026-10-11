import XCTest

final class PhotoDetailRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRemovingLastHeartedPhotoStillAllowsClosingDetail() throws {
        let app = XCUIApplication()
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
