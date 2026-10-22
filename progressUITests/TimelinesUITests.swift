import XCTest

final class TimelinesUITests: XCTestCase {
    @MainActor
    func testLocalTimelineDeletionKeepsCloudCopyAndDeletesDeviceTimeline() throws {
        continueAfterFailure = false
        let app = launchApp(local: true)
        openSettings(app)
        createTimeline("Alex", in: app)
        app.buttons["editTimelineButton"].tap()
        let deletion = app.buttons["deleteTimelineButton"]
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        for _ in 0..<4 where !deletion.isHittable { app.swipeUp() }
        deletion.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Any kept iCloud copies are unchanged and return")).firstMatch.exists)
        XCTAssertFalse(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "including other synced devices")).firstMatch.exists)
        confirmation.buttons["Delete Timeline"].tap()
        assertCurrentTimeline("Default", in: app)
        XCTAssertFalse(timelineButton("Alex", in: app).exists)
    }

    @MainActor
    func testDuplicateNamesAreBlockedDuringCreationAndRenaming() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        app.buttons["newTimelineButton"].tap()
        let field = app.textFields["timelineNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" default ")
        let save = app.buttons["saveTimelineButton"]
        let error = app.staticTexts["duplicateTimelineNameError"]
        XCTAssertTrue(error.exists)
        XCTAssertFalse(save.isEnabled)
        replaceName("Alex", in: field)
        XCTAssertFalse(error.exists)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        assertCurrentTimeline("Alex", in: app)

        app.buttons["newTimelineButton"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" ALEX ")
        XCTAssertTrue(error.exists)
        XCTAssertFalse(save.isEnabled)
        app.buttons["Cancel"].tap()

        app.buttons["editTimelineButton"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists, "Edit Timeline saves through Close instead of a second save button.")
        let close = app.buttons["closeTimelineEditorButton"]
        replaceName("DEFAULT", in: field)
        XCTAssertTrue(error.exists)
        close.tap()
        XCTAssertTrue(app.navigationBars["Edit Timeline"].exists)
        XCTAssertTrue(error.exists)
        replaceName("", in: field)
        close.tap()
        XCTAssertTrue(app.staticTexts["timelineNameValidationError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Edit Timeline"].exists)
        replaceName("alex", in: field)
        XCTAssertFalse(error.exists)
        close.tap()
        assertCurrentTimeline("alex", in: app)
    }

    @MainActor
    func testSingleTimelineCanBeRenamedButNotDeleted() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        app.buttons["editTimelineButton"].tap()
        let field = app.textFields["timelineNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let close = app.buttons["closeTimelineEditorButton"]
        XCTAssertEqual(close.label, "Close", "The × retains its accessible Close label.")
        XCTAssertFalse(close.staticTexts["Close"].exists, "Edit Timeline uses an icon instead of visible Close text.")
        let deletion = app.buttons["deleteTimelineButton"]
        for _ in 0..<3 where !deletion.isHittable { app.swipeUp() }
        XCTAssertTrue(deletion.exists)
        XCTAssertFalse(deletion.isEnabled)
        for _ in 0..<3 where !field.isHittable { app.swipeDown() }
        replaceName("Myself", in: field)
        let reminders = app.buttons["timelineRemindersLink"]
        for _ in 0..<3 where !reminders.isHittable { app.swipeUp() }
        reminders.tap()
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))
        app.navigationBars["Reminders"].buttons["Edit Timeline"].tap()
        XCTAssertEqual(field.value as? String, "Myself", "Reminder navigation must preserve an unsaved name.")
        XCTAssertFalse(app.buttons["saveTimelineButton"].exists)
        app.buttons["closeTimelineEditorButton"].tap()
        assertCurrentTimeline("Myself", in: app)
        app.buttons["editTimelineButton"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Myself")
        app.buttons["closeTimelineEditorButton"].tap()
    }

    @MainActor
    func testDeletingDefaultSelectsTheSurvivingTimeline() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        createTimeline("Alex", in: app)
        timelineButton("Default", in: app).tap()
        app.buttons["editTimelineButton"].tap()
        let deletion = app.buttons["deleteTimelineButton"]
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        for _ in 0..<4 where !deletion.isHittable { app.swipeUp() }
        XCTAssertTrue(deletion.isEnabled)
        deletion.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Other timelines are kept")).firstMatch.exists)
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "including other synced devices")).firstMatch.exists)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        deletion.tap()
        confirmation.buttons["Delete Timeline"].tap()
        assertCurrentTimeline("Alex", in: app)
        XCTAssertFalse(timelineButton("Default", in: app).exists)
        app.buttons["editTimelineButton"].tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        XCTAssertFalse(deletion.isEnabled)
        app.buttons["closeTimelineEditorButton"].tap()
        app.buttons["Close"].tap()
        openSettings(app)
        assertCurrentTimeline("Alex", in: app)
        XCTAssertFalse(timelineButton("Default", in: app).exists)
        attachScreenshot(app, name: "Timelines – Default Deleted")
    }

    @MainActor
    func testTimelineButtonsWrapWithAnInlinePlus() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        for name in ["Alexandra", "Benjamin", "Charlotte"] { createTimeline(name, in: app) }
        let first = timelineButton("Default", in: app)
        let last = timelineButton("Charlotte", in: app)
        let plus = app.buttons["newTimelineButton"]
        XCTAssertGreaterThan(last.frame.minY, first.frame.minY)
        XCTAssertEqual(plus.frame.midY, last.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(plus.frame.minX, last.frame.maxX)
        attachScreenshot(app, name: "Timelines – Wrapping Buttons")
    }

    @MainActor
    func testCreatingSwitchingAndRenamingTimelinesFromSettings() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        assertCurrentTimeline("Default", in: app)
        XCTAssertTrue(app.buttons["editTimelineButton"].exists)

        let newTimeline = app.buttons["newTimelineButton"]
        XCTAssertTrue(newTimeline.isHittable, "Timelines should appear at the top of Settings.")
        XCTAssertTrue(newTimeline.isEnabled)
        newTimeline.tap()
        let name = app.textFields["timelineNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["saveTimelineButton"]
        XCTAssertFalse(save.isEnabled)
        name.tap()
        name.typeText("Alex")
        XCTAssertTrue(save.isEnabled)
        attachScreenshot(app, name: "Timelines – Create")
        save.tap()
        assertCurrentTimeline("Alex", in: app)
        XCTAssertTrue(app.buttons["editTimelineButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(timelineButton("Default", in: app).exists)
        XCTAssertTrue(timelineButton("Alex", in: app).exists)
        attachScreenshot(app, name: "Timelines – Switcher")

        app.buttons["editTimelineButton"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceName("Alexis", in: name)
        app.buttons["closeTimelineEditorButton"].tap()
        assertCurrentTimeline("Alexis", in: app)
        XCTAssertTrue(timelineButton("Alexis", in: app).exists)

        timelineButton("Default", in: app).tap()
        assertCurrentTimeline("Default", in: app)
        app.buttons["editTimelineButton"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceName("Me", in: name)
        app.buttons["closeTimelineEditorButton"].tap()
        assertCurrentTimeline("Me", in: app)
        timelineButton("Alexis", in: app).tap()
        assertCurrentTimeline("Alexis", in: app)

        app.buttons["Close"].tap()
        openSettings(app)
        assertCurrentTimeline("Alexis", in: app)
        XCTAssertTrue(timelineButton("Me", in: app).exists)
    }

    @MainActor
    func testRemindersFollowTheTimelineSelectedInSettings() throws {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["Storage"].exists)
        XCTAssertFalse(app.buttons["timelineRemindersLink"].exists)
        attachScreenshot(app, name: "Settings – Storage")
        openReminders(app, capturesEditor: true)
        app.buttons["Add Time"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1)
        returnToSettings(app)

        let newTimeline = app.buttons["newTimelineButton"]
        XCTAssertTrue(newTimeline.isEnabled)
        newTimeline.tap()
        let name = app.textFields["timelineNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Sam")
        app.buttons["saveTimelineButton"].tap()
        assertCurrentTimeline("Sam", in: app)
        openReminders(app)
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)
        let skipToggle = app.switches["skipRemindersAfterPhotoToggle"]
        XCTAssertEqual(skipToggle.value as? String, "1")
        skipToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(skipToggle.value as? String, "0")
        returnToSettings(app)

        timelineButton("Default", in: app).tap()
        assertCurrentTimeline("Default", in: app)
        openReminders(app)
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 1)
        XCTAssertEqual(skipToggle.value as? String, "1")
        returnToSettings(app)
        timelineButton("Sam", in: app).tap()
        openReminders(app)
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 0)
        XCTAssertEqual(skipToggle.value as? String, "0")
    }

    @MainActor
    private func launchApp(local: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_REMINDERS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        if local { app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local" }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["newTimelineButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openReminders(_ app: XCUIApplication, capturesEditor: Bool = false) {
        let edit = app.buttons["editTimelineButton"]
        for _ in 0..<3 where !edit.isHittable { app.swipeDown() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Timeline"].waitForExistence(timeout: 5))
        if capturesEditor { attachScreenshot(app, name: "Timeline – Edit") }
        let link = app.buttons["timelineRemindersLink"]
        for _ in 0..<3 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.buttons["Add Time"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func returnToSettings(_ app: XCUIApplication) {
        app.navigationBars["Reminders"].buttons["Edit Timeline"].tap()
        allowNotificationsIfPrompted()
        let done = app.buttons["closeTimelineEditorButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Close")
        done.tap()
        let newTimeline = app.buttons["newTimelineButton"]
        XCTAssertTrue(newTimeline.waitForExistence(timeout: 5))
        for _ in 0..<3 where !newTimeline.isHittable { app.swipeDown() }
    }

    @MainActor
    private func timelineButton(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "timelineOption-", name)).firstMatch
    }

    @MainActor
    private func createTimeline(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["newTimelineButton"]
        for _ in 0..<3 where !add.isHittable { app.swipeDown() }
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = app.textFields["timelineNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["saveTimelineButton"].tap()
        assertCurrentTimeline(name, in: app)
    }

    @MainActor
    private func assertCurrentTimeline(_ name: String, in app: XCUIApplication) {
        let currentName = app.staticTexts["currentTimelineName"]
        let expected = NSPredicate(format: "label == %@", name)
        let expectation = XCTNSPredicateExpectation(predicate: expected, object: currentName)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func replaceName(_ value: String, in field: XCUIElement) {
        let previous = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    }

    @MainActor
    private func allowNotificationsIfPrompted() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3), alert.buttons["Allow"].exists {
            alert.buttons["Allow"].tap()
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
