import XCTest

final class PhotoImportUITests: XCTestCase {
    @MainActor
    func testPrivateImportDoesNotConsumeTheFirstLibraryPermissionRequest() {
        let app = launchImportWithNoPhotosPermission()
        app.buttons["Import Photos Privately"].tap()
        let cancel = pickerCancelButton(in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        app.buttons["Import Photos"].tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        permission.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Don'")).firstMatch.tap()

        let guidance = app.alerts["Full Photos Access Needed"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertTrue(guidance.buttons["Open Settings"].exists)
        guidance.buttons["Import Privately"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        app.buttons["Import Photos"].tap()
        XCTAssertTrue(guidance.waitForExistence(timeout: 5), app.debugDescription)
        guidance.buttons["Open Settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let photosSetting = settings.staticTexts["Photos"]
        // Some simulator runtimes open Settings at its root instead of the app page.
        if !photosSetting.waitForExistence(timeout: 3) {
            let apps = settings.buttons["Apps"]
            for _ in 0..<6 where !apps.isHittable { settings.swipeUp() }
            XCTAssertTrue(apps.waitForExistence(timeout: 5), settings.debugDescription)
            apps.tap()
            let search = settings.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5), settings.debugDescription)
            search.tap()
            search.typeText("Work in Progress")
            let appSettings = settings.staticTexts["Work in Progress"]
            XCTAssertTrue(appSettings.waitForExistence(timeout: 5), settings.debugDescription)
            appSettings.tap()
        }
        XCTAssertTrue(photosSetting.waitForExistence(timeout: 10), settings.debugDescription)
        photosSetting.tap()
        let fullAccess = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Full Access'")).firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5), settings.debugDescription)
        fullAccess.tap()
        let confirmation = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if confirmation.waitForExistence(timeout: 3) {
            confirmation.buttons["Allow Full Access"].tap()
        }
        app.activate()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertEqual(app.buttons["Import Photos"].value as? String,
                       "Includes Live Photos. Full Photos access enabled.")
        XCTAssertFalse(app.buttons["Import Photos Privately"].exists)
    }

    @MainActor
    func testAlbumImportContinuesAfterGrantingFullAccess() {
        let app = launchImportWithNoPhotosPermission()
        app.buttons["Import Album"].tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        permission.buttons["Allow Full Access"].tap()

        XCTAssertTrue(app.navigationBars["Import Album"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["Import Album"].buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["Import Album"].value as? String,
                       "Includes Live Photos. Full Photos access enabled.")
        XCTAssertFalse(app.buttons["Import Photos Privately"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Import Options · Full Access"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchImportWithNoPhotosPermission() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        let leftoverPermission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            .matching(NSPredicate(format: "label CONTAINS[c] 'photo'")).firstMatch
        if leftoverPermission.exists {
            if leftoverPermission.buttons["Cancel"].exists {
                leftoverPermission.buttons["Cancel"].tap()
            } else {
                leftoverPermission.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Don'")).firstMatch.tap()
            }
        }
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["-hasCompletedIntroduction", "YES"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["SIMULATOR_EXAMPLE_PHOTOS"] = "0"
        app.launch()
        // A previously interrupted Settings trip may have restored the import sheet.
        let restoredClose = app.buttons["Close"]
        if restoredClose.exists, restoredClose.isHittable {
            restoredClose.tap()
            XCTAssertTrue(restoredClose.waitForNonExistence(timeout: 5))
        }
        let storage = app.buttons["emptyStatePhotoStorageLink"]
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        storage.tap()
        XCTAssertTrue(app.navigationBars["Photo Storage"].waitForExistence(timeout: 5), app.debugDescription)
        let importLink = app.buttons["importSettingsLink"]
        for _ in 0..<4 where !importLink.isHittable { app.swipeUp() }
        XCTAssertTrue(importLink.waitForExistence(timeout: 5), app.debugDescription)
        importLink.tap()
        XCTAssertTrue(app.buttons["Import Photos"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Import Photos"].value as? String,
                       "Includes Live Photos. Requires Full Photos access.")
        XCTAssertTrue(app.buttons["Import Photos Privately"].exists)
        return app
    }

    @MainActor
    private func pickerCancelButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Cancel"]
    }
}
