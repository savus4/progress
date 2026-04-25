//
//  progressUITests.swift
//  progressUITests
//
//  Created by Simon Riepl on 19.02.26.
//

import XCTest

final class progressUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testCaptureSaveReturnsPhotoToGridAndShowsUploadState() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "UI_TEST_IN_MEMORY_STORE",
            "UI_TEST_MOCK_CAPTURE"
        ]
        app.launch()

        let openCameraButton = app.buttons["emptyStateCaptureButton"]
        XCTAssertTrue(openCameraButton.waitForExistence(timeout: 5))
        openCameraButton.tap()

        let shutterButton = app.buttons["experimentalCameraShutter"]
        XCTAssertTrue(shutterButton.waitForExistence(timeout: 5))
        shutterButton.tap()

        let capturePreviewOverlay = app.otherElements["capturePreviewOverlay"]
        XCTAssertTrue(capturePreviewOverlay.waitForExistence(timeout: 5))

        let doneButton = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: capturePreviewOverlay)
        waitForExpectations(timeout: 5)

        let gridItem = app.otherElements["photoGridItem"].firstMatch
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))

        let uploadBadge = app.otherElements["photoGridUploadBadge"].firstMatch
        let uploadBanner = app.otherElements["photoGridUploadBanner"].firstMatch
        XCTAssertTrue(uploadBadge.waitForExistence(timeout: 3) || uploadBanner.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testPhotoPagerSwipeRepro() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "UI_TEST_IN_MEMORY_STORE",
            "UI_TEST_MOCK_CAPTURE"
        ]
        app.launch()

        captureMockPhoto(app: app, initialCapture: true)
        captureMockPhoto(app: app, initialCapture: false)
        captureMockPhoto(app: app, initialCapture: false)

        let gridItem = app.cells.firstMatch
        XCTAssertTrue(gridItem.waitForExistence(timeout: 5))
        gridItem.tap()

        let pagerScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(pagerScrollView.waitForExistence(timeout: 5))

        for _ in 0..<5 {
            pagerScrollView.swipeLeft()
            pagerScrollView.swipeRight()
        }
    }

    @MainActor
    func testPhotoPagerSwipeOnExistingLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let firstGridItem = app.cells.firstMatch
        guard firstGridItem.waitForExistence(timeout: 8) else {
            throw XCTSkip("No existing photos available to exercise pager swipe on device.")
        }

        firstGridItem.tap()

        let pagerScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(pagerScrollView.waitForExistence(timeout: 5))

        for _ in 0..<8 {
            pagerScrollView.swipeLeft()
            pagerScrollView.swipeRight()
        }
    }

    @MainActor
    private func captureMockPhoto(app: XCUIApplication, initialCapture: Bool) {
        let openCameraButton = initialCapture ? app.buttons["emptyStateCaptureButton"] : app.buttons["gridCaptureButton"]
        XCTAssertTrue(openCameraButton.waitForExistence(timeout: 5))
        openCameraButton.tap()

        let shutterButton = app.buttons["experimentalCameraShutter"]
        XCTAssertTrue(shutterButton.waitForExistence(timeout: 5))
        shutterButton.tap()

        let capturePreviewOverlay = app.otherElements["capturePreviewOverlay"]
        XCTAssertTrue(capturePreviewOverlay.waitForExistence(timeout: 5))

        let doneButton = app.buttons["capturePreviewDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: capturePreviewOverlay)
        waitForExpectations(timeout: 5)

        let gridCaptureButton = app.buttons["gridCaptureButton"]
        XCTAssertTrue(gridCaptureButton.waitForExistence(timeout: 5))
    }
}
