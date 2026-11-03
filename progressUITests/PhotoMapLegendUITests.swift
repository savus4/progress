import XCTest

final class PhotoMapLegendUITests: XCTestCase {
    @MainActor
    func testPhotosInOneYearShowMonths() {
        assertLegend(scenario: "single-year", title: "Month", labels: ["Jan", "May", "Oct"])
    }

    @MainActor
    func testPhotosAcrossYearsShowYears() {
        assertLegend(scenario: "multiple-years", title: "Year", labels: ["24", "25", "26"])
    }

    @MainActor
    func testPhotosCrossingNewYearKeepYearsEvenWithinTwelveMonths() {
        assertLegend(scenario: "year-boundary", title: "Year", labels: ["25", "26", "26"])
    }

    @MainActor
    func testSinglePhotoShowsItsMonth() {
        assertLegend(scenario: "single-photo", title: "Month", labels: ["Sep", "Sep", "Sep"], photoCount: 1)
    }

    @MainActor
    private func assertLegend(scenario: String, title: String, labels: [String], photoCount: Int = 3) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedIntroduction", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["UI_TEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UI_TEST_RESET_TIMELINES"] = "1"
        app.launchEnvironment["UI_TEST_RESET_REMINDERS"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_MODE"] = "local"
        app.launchEnvironment["UI_TEST_MAP_LEGEND_SCENARIO"] = scenario
        app.launchEnvironment["SIMULATOR_EXAMPLE_PHOTOS"] = "0"
        app.launchEnvironment["STORAGE_TEST_HOST"] = "0"
        app.launch()
        defer { app.terminate() }

        let mapButton = app.buttons["gridMapButton"]
        XCTAssertTrue(mapButton.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(mapButton.label, "Show Photo Map")
        let photos = app.cells.matching(identifier: "photoGridItem")
        XCTAssertTrue(photos.element(boundBy: photoCount - 1).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(photos.count, photoCount)
        mapButton.tap()

        let legendTitle = app.staticTexts["routeMapAgeLegendTitle"]
        XCTAssertTrue(legendTitle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(legendTitle.label, title)
        for (index, expectedLabel) in labels.enumerated() {
            let label = app.staticTexts["routeMapAgeLegendLabel\(index)"]
            XCTAssertTrue(label.exists, app.debugDescription)
            XCTAssertEqual(label.label, expectedLabel)
        }
        XCTAssertFalse(app.otherElements["routeMapNoLocations"].exists)
        XCTAssertEqual(mapButton.label, "Show Photo Grid")
        let photoAnnotations = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,"))
        XCTAssertTrue(photoAnnotations.element(boundBy: photoCount - 1).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(photoAnnotations.count, photoCount)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Map legend - \(scenario)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
