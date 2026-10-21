import XCTest

final class ReminderSettingsUITests: XCTestCase {
    @MainActor
    func testReminderEditsAfterReturningFromStorageManagementPersist() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_REMINDERS"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        openNotifications(app)
        XCTAssertTrue(app.buttons["Add Time"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)

        visitStorageManagementAndReturn(app)
        openNotifications(app)

        let addTime = app.buttons["Add Time"]
        for _ in 0..<5 where !addTime.isHittable { app.swipeDown() }
        XCTAssertTrue(addTime.isHittable)
        addTime.tap()
        let addedReminder = app.buttons["Remove reminder"]
        for _ in 0..<5 where !addedReminder.isHittable { app.swipeDown() }
        XCTAssertTrue(addedReminder.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1)
        returnToSettings(app)

        // A clean simulator may ask permission after saving the first reminder.
        let permissionAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permissionAlert.waitForExistence(timeout: 3) {
            let allow = permissionAlert.buttons["Allow"]
            if allow.exists { allow.tap() }
        }
        app.buttons["Close"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        openNotifications(app)
        XCTAssertTrue(addTime.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove reminder"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1,
                       "The reminder added after returning from Storage Management must survive reopening Settings.")

        // Also verify that a later edit can remove the saved reminder.
        visitStorageManagementAndReturn(app)
        openNotifications(app)
        let removeReminder = app.buttons["Remove reminder"]
        for _ in 0..<5 where !removeReminder.isHittable { app.swipeDown() }
        removeReminder.tap()
        returnToSettings(app)
        app.buttons["Close"].tap()
        settings.tap()
        openNotifications(app)
        XCTAssertTrue(addTime.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)
    }

    @MainActor
    private func visitStorageManagementAndReturn(_ app: XCUIApplication) {
        returnToSettings(app)
        let photoStorage = app.buttons["photoStorageSettingsLink"]
        XCTAssertTrue(photoStorage.waitForExistence(timeout: 5))
        photoStorage.tap()
        XCTAssertTrue(app.navigationBars["Photo Storage"].waitForExistence(timeout: 5))
        let storage = app.buttons["Storage Management"]
        for _ in 0..<5 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.isHittable)
        storage.tap()
        let back = app.navigationBars["Storage Management"].buttons["Photo Storage"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let settingsBack = app.navigationBars["Photo Storage"].buttons["Settings"]
        XCTAssertTrue(settingsBack.waitForExistence(timeout: 5))
        settingsBack.tap()
    }

    @MainActor
    func testNotificationTogglePersistsAndImportOptionsHaveTheirOwnSubmenu() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_REMINDERS"] = "1"
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["notificationSettingsLink"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add Time"].exists)
        XCTAssertFalse(app.buttons["Import Photos"].exists)
        openNotifications(app)

        let toggle = app.switches["skipRemindersAfterPhotoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        returnToSettings(app)
        app.buttons["Close"].tap()
        settings.tap()
        openNotifications(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        returnToSettings(app)

        app.buttons["importSettingsLink"].tap()
        XCTAssertTrue(app.navigationBars["Import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Photos"].exists)
        XCTAssertTrue(app.buttons["Import Album"].exists)
        XCTAssertTrue(app.buttons["Import Privately (No Live Photos)"].exists)
    }

    @MainActor
    private func openNotifications(_ app: XCUIApplication) {
        let notifications = app.buttons["notificationSettingsLink"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func returnToSettings(_ app: XCUIApplication) {
        let back = app.navigationBars["Notifications"].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }
}
