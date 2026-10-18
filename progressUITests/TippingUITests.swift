import StoreKitTest
import XCTest

final class TippingUITests: XCTestCase {
    @MainActor
    func testTipCardCustomAmountAndThankYou() throws {
        continueAfterFailure = false
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let custom = app.buttons["tip-custom"]
        scrollTo(custom, in: app)
        XCTAssertTrue(app.buttons["tip-chips"].label.contains("$3.00"))
        XCTAssertTrue(app.buttons["tip-fries"].label.contains("$5.00"))
        attachScreenshot(app, name: "Tip card")
        custom.tap()

        let total = app.staticTexts["custom-tip-total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertEqual(total.label, "$10.00")
        let stepper = app.steppers["custom-tip-stepper"]
        XCTAssertFalse(stepper.buttons["custom-tip-stepper-Decrement"].isEnabled)
        stepper.buttons["custom-tip-stepper-Increment"].tap()
        XCTAssertEqual(total.label, "$20.00")
        attachScreenshot(app, name: "Custom tip – minimum ten dollars")

        let purchase = app.buttons["custom-tip-purchase"]
        scrollTo(purchase, in: app)
        purchase.tap()
        let thankYou = app.staticTexts["tip-thank-you-title"]
        XCTAssertTrue(thankYou.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["tip-received"].label.contains("$20.00"))
        attachScreenshot(app, name: "Thank you – verified custom tip")
        dismissThankYou(in: app)

        for id in ["tip-chips", "tip-chips", "tip-fries"] {
            let tip = app.buttons[id]
            scrollTo(tip, in: app)
            tip.tap()
            XCTAssertTrue(thankYou.waitForExistence(timeout: 10))
            dismissThankYou(in: app)
        }
    }

    @MainActor
    private func dismissThankYou(in app: XCUIApplication) {
        let done = app.buttons["tip-thank-you-done"]
        scrollTo(done, in: app)
        done.tap()
        XCTAssertTrue(app.buttons["tip-custom"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
