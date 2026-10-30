import XCTest

final class IntroductionUITests: XCTestCase {
    @MainActor
    func testCompletionAfterBackgroundingIntroduction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchArguments = ["-hasCompletedIntroduction", "NO"]
        app.launch()

        let continueButton = app.buttons["introductionContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertEqual(continueButton.label, "Get Started")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["settingsTitle"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["emptyStateCaptureButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCompletionAndHiddenReplayAcrossLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchArguments = ["-hasCompletedIntroduction", "NO"]
        app.launch()

        let continueButton = app.buttons["introductionContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Settings"].exists)
        attachScreenshot(app, name: "Introduction – Video preview")
        app.scrollViews["introductionPreviewPage"].swipeLeft()

        for title in [
            "Years of photos. Still fast.",
            "Life in every Live Photo",
            "Remember where",
            "Your memories stay yours"
        ] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
        }
        XCTAssertEqual(continueButton.label, "Get Started")
        attachScreenshot(app, name: "Introduction – Features")
        app.scrollViews["introductionFeaturesPage"].swipeRight()
        XCTAssertEqual(continueButton.label, "Continue")
        continueButton.tap()
        XCTAssertEqual(continueButton.label, "Get Started")
        XCTAssertFalse(app.buttons["Back to Preview"].exists)
        continueButton.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchArguments = []
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Finishing the introduction must persist across launches.")
        XCTAssertFalse(continueButton.exists)
        settings.tap()

        let title = app.staticTexts["settingsTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let confirmation = app.alerts["Introduction Scheduled"]
        title.press(forDuration: 1)
        XCTAssertFalse(confirmation.exists, "A short hold must not schedule the introduction.")
        title.press(forDuration: 3.2)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["OK"].tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.exists, "Scheduling a replay must leave the current session alone.")

        app.terminate()
        app.launch()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "The hidden action must replay the introduction on the next launch.")
        XCTAssertEqual(continueButton.label, "Continue")
        continueButton.tap()
        continueButton.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
