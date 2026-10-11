import XCTest

final class ReminderSettingsUITests: XCTestCase {
    @MainActor
    func testReminderEditsAfterReturningFromStorageManagementPersist() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_REMINDERS"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["Add Time"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)

        visitStorageManagementAndReturn(app)

        let addTime = app.buttons["Add Time"]
        for _ in 0..<5 where !addTime.isHittable { app.swipeDown() }
        XCTAssertTrue(addTime.isHittable)
        addTime.tap()
        let addedReminder = app.buttons["Remove reminder"]
        for _ in 0..<5 where !addedReminder.isHittable { app.swipeDown() }
        XCTAssertTrue(addedReminder.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1)
        app.buttons["Close"].tap()

        // A clean simulator may ask permission after saving the first reminder.
        let permissionAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permissionAlert.waitForExistence(timeout: 3) {
            let allow = permissionAlert.buttons["Allow"]
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(addTime.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove reminder"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1,
                       "The reminder added after returning from Storage Management must survive reopening Settings.")

        // Also verify that a later edit can remove the saved reminder.
        visitStorageManagementAndReturn(app)
        let removeReminder = app.buttons["Remove reminder"]
        for _ in 0..<5 where !removeReminder.isHittable { app.swipeDown() }
        removeReminder.tap()
        app.buttons["Close"].tap()
        settings.tap()
        XCTAssertTrue(addTime.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)
    }

    @MainActor
    private func visitStorageManagementAndReturn(_ app: XCUIApplication) {
        let storage = app.buttons["Storage Management"]
        for _ in 0..<5 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.isHittable)
        storage.tap()
        let back = app.navigationBars["Storage Management"].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        // Returning preserves the Form's position near the Storage link. Move
        // the Notifications section fully into view before editing its controls.
        app.swipeDown()
        app.swipeDown()
    }
}
