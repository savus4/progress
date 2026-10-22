import XCTest

final class PhotoStorageSettingsUITests: XCTestCase {
    @MainActor
    func testSimulatorExamplesShowTheirActualLocalStorageMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["SIMULATOR_EXAMPLE_PHOTOS"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Simulator example library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Simulator example photos stay on this simulator. iCloud sync is disabled for this example library."].exists)
        app.buttons["photoStorageSettingsLink"].tap()
        let toggle = app.switches["iCloudSyncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(app.staticTexts["photoStorageExplanation"].label.contains("example library"))
    }

    @MainActor
    func testEmptyLibraryExplanationOpensPhotoStorageDirectly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["SIMULATOR_EXAMPLE_PHOTOS"] = "0"
        app.launch()

        let explanation = app.buttons["emptyStatePhotoStorageLink"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        XCTAssertTrue(explanation.label.contains("iCloud"))
        explanation.tap()
        XCTAssertTrue(app.navigationBars["Photo Storage"].waitForExistence(timeout: 5))
        let toggle = app.switches["iCloudSyncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")

        // SwiftUI exposes both the labeled form row and its native switch.
        // Tap the native control to turn iCloud sync off.
        let control = toggle.switches.firstMatch
        XCTAssertTrue(control.exists)
        control.tap()
        let localStorageSheet = app.navigationBars["Use Local Storage"]
        XCTAssertTrue(localStorageSheet.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["keepICloudCopiesButton"].exists)
        XCTAssertTrue(app.buttons["removeICloudCopiesButton"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Local Storage Choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        localStorageSheet.buttons["Cancel"].tap()
        XCTAssertTrue(localStorageSheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "Cancel must preserve the existing iCloud preference.")
    }

    @MainActor
    func testSettingsHasPhotoStorageLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["SIMULATOR_EXAMPLE_PHOTOS"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let link = app.buttons["photoStorageSettingsLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Storage"].exists)
        let photoImport = app.buttons["importSettingsLink"]
        XCTAssertFalse(photoImport.exists, "Import belongs in Photo Storage’s Advanced section.")
        XCTAssertFalse(app.buttons["timelineRemindersLink"].exists,
                       "Reminders belong inside Edit Timeline.")
        XCTAssertFalse(app.buttons["storageManagementSettingsLink"].exists,
                       "Storage Management belongs inside Photo Storage.")
        link.tap()
        XCTAssertTrue(app.switches["iCloudSyncToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Advanced"].exists)
        for _ in 0..<4 where !photoImport.isHittable { app.swipeUp() }
        XCTAssertTrue(photoImport.waitForExistence(timeout: 5))
        photoImport.tap()
        XCTAssertTrue(app.navigationBars["Import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Photos"].exists)
        XCTAssertTrue(app.buttons["Import Album"].exists)
        XCTAssertTrue(app.buttons["Import Privately (No Live Photos)"].exists)
        app.navigationBars["Import"].buttons["Photo Storage"].tap()
        XCTAssertTrue(app.navigationBars["Photo Storage"].waitForExistence(timeout: 5))
        let advanced = app.buttons["storageManagementSettingsLink"]
        for _ in 0..<4 where !advanced.isHittable { app.swipeUp() }
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Storage Management"].waitForExistence(timeout: 5))
        app.navigationBars["Storage Management"].buttons["Photo Storage"].tap()
        XCTAssertTrue(app.navigationBars["Photo Storage"].waitForExistence(timeout: 5))
        app.navigationBars["Photo Storage"].buttons["Settings"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
    }
}
