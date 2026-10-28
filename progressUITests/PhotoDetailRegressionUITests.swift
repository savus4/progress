import XCTest

final class PhotoDetailRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSecondGridPhotoCanOpenAndReturnRepeatedlyWithoutMovingGrid() throws {
        let app = launchMockPhotoLibrary()
        captureMockPhoto(app: app, initialCapture: true)
        captureMockPhoto(app: app, initialCapture: false)

        let gridItems = app.cells.matching(identifier: "photoGridItem")
        let firstPhoto = gridItems.element(boundBy: 0)
        let secondPhoto = gridItems.element(boundBy: 1)
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 5))
        let initialFirstFrame = firstPhoto.frame
        let initialSecondFrame = secondPhoto.frame
        let backButton = app.buttons["Back"]
        let detailImage = app.descendants(matching: .any)["photoDetailImage"].firstMatch

        for opening in 1...2 {
            secondPhoto.tap()
            XCTAssertTrue(backButton.waitForExistence(timeout: 5))
            XCTAssertTrue(detailImage.waitForExistence(timeout: 5))
            XCTAssertTrue(backButton.isHittable)
            XCTAssertTrue(detailImage.isHittable)
            XCTAssertEqual(detailImage.label, "Photo")
            XCTAssertGreaterThan(detailImage.frame.width, 0)
            XCTAssertGreaterThan(detailImage.frame.height, 0)

            let action = app.buttons[opening == 1 ? "Favorite" : "Remove Favorite"]
            let updatedAction = app.buttons[opening == 1 ? "Remove Favorite" : "Favorite"]
            XCTAssertTrue(action.isEnabled)
            XCTAssertTrue(action.isHittable)
            action.tap()
            XCTAssertTrue(updatedAction.waitForExistence(timeout: 5), "Detail controls should work after each opening.")
            attachScreenshot(app: app, name: "Second photo opened \(opening)")

            backButton.tap()
            XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
            XCTAssertTrue(detailImage.waitForNonExistence(timeout: 5))
            XCTAssertTrue(secondPhoto.waitForExistence(timeout: 5))
            XCTAssertTrue(secondPhoto.isHittable, "The destination cell should be restored after closing.")
            XCTAssertEqual(gridItems.count, 2)
            XCTAssertEqual(secondPhoto.value as? String ?? "", opening == 1 ? "Favorite" : "")

            for (photo, initialFrame) in [(firstPhoto, initialFirstFrame), (secondPhoto, initialSecondFrame)] {
                XCTAssertEqual(photo.frame.minX, initialFrame.minX, accuracy: 0.5)
                XCTAssertEqual(photo.frame.minY, initialFrame.minY, accuracy: 0.5, "Opening and closing should preserve the grid scroll position.")
                XCTAssertEqual(photo.frame.width, initialFrame.width, accuracy: 0.5)
                XCTAssertEqual(photo.frame.height, initialFrame.height, accuracy: 0.5)
            }
            attachScreenshot(app: app, name: "Grid restored after second photo opening \(opening)")
        }
    }

    @MainActor
    func testPhotoDismissalCanCancelAndReturnDiagonallyToGrid() throws {
        let app = launchMockPhotoLibrary()
        captureMockPhoto(app: app, initialCapture: true)

        let gridItem = app.cells["photoGridItem"].firstMatch
        gridItem.tap()

        let backButton = app.buttons["Back"]
        let detailImage = app.descendants(matching: .any)["photoDetailImage"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(detailImage.waitForExistence(timeout: 5))

        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let shortDragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.47))
        dragStart.press(forDuration: 0.1, thenDragTo: shortDragEnd, withVelocity: .slow, thenHoldForDuration: 0.25)

        XCTAssertTrue(backButton.isHittable, "A short drag should return the photo to its detail position.")
        XCTAssertTrue(detailImage.isHittable)
        attachScreenshot(app: app, name: "Photo detail after cancelled drag")

        let dismissalEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.76))
        dragStart.press(forDuration: 0.1, thenDragTo: dismissalEnd, withVelocity: .slow, thenHoldForDuration: 0.1)

        XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(detailImage.waitForNonExistence(timeout: 5))
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
        XCTAssertTrue(gridItem.isHittable, "The photo should return to an interactive grid cell after dismissal.")
        attachScreenshot(app: app, name: "Photo grid after diagonal dismissal")

        gridItem.tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(detailImage.waitForExistence(timeout: 5))
        backButton.tap()
        XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(gridItem.isHittable)
    }

    @MainActor
    func testHorizontalPhotoPagingStillWorksWithDismissalGesture() throws {
        let app = launchMockPhotoLibrary()
        captureMockPhoto(app: app, initialCapture: true)
        captureMockPhoto(app: app, initialCapture: false)

        app.cells["photoGridItem"].firstMatch.tap()
        let favoriteButton = app.buttons["Favorite"]
        let removeFavoriteButton = app.buttons["Remove Favorite"]
        let backButton = app.buttons["Back"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5))
        favoriteButton.tap()
        XCTAssertTrue(removeFavoriteButton.waitForExistence(timeout: 5))

        let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.45))
        let leftSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
        rightSide.press(forDuration: 0.1, thenDragTo: leftSide)

        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5), "Swiping left should show the other, unfavorited photo.")
        XCTAssertTrue(backButton.isHittable)
        leftSide.press(forDuration: 0.1, thenDragTo: rightSide)
        XCTAssertTrue(removeFavoriteButton.waitForExistence(timeout: 5), "Swiping right should return to the favorited photo.")
        attachScreenshot(app: app, name: "Photo detail after horizontal paging")

        backButton.tap()
        XCTAssertTrue(backButton.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.cells.matching(identifier: "photoGridItem").count, 2)
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

    @MainActor
    private func launchMockPhotoLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES", "UI_TEST_IN_MEMORY_STORE", "UI_TEST_MOCK_CAPTURE"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_MOCK_CAPTURE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func captureMockPhoto(app: XCUIApplication, initialCapture: Bool) {
        let captureButton = app.buttons[initialCapture ? "emptyStateCaptureButton" : "gridCaptureButton"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        captureButton.tap()

        let doneButton = app.buttons["capturePreviewDoneButton"]
        if !doneButton.waitForExistence(timeout: 1) {
            let shutterButton = app.buttons["experimentalCameraShutter"]
            XCTAssertTrue(shutterButton.waitForExistence(timeout: 5))
            shutterButton.tap()
        }
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(doneButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.cells["photoGridItem"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["gridCaptureButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
