import XCTest

@MainActor
final class ForesightUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-in-memory-store"]
        app.launch()
    }

    private func openLog(named text: String) {
        let log = app.staticTexts[text].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 3))
        log.tap()
    }

    func testFreshLaunchShowsJournal() {
        XCTAssertTrue(app.staticTexts["Journal"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New log"].exists)
    }

    func testAccessibilityTextSizeKeepsPrimaryNavigationReachable() {
        app.terminate()
        app.launchArguments = [
            "-in-memory-store",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["New log"].waitForExistence(timeout: 3))
        for tab in ["Journal", "Check In", "Patterns"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
    }

    func testCreateEditAndDeleteLog() {
        app.buttons["New log"].tap()
        let editor = app.textViews["What happened?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("A test journal log")
        app.buttons["Save"].firstMatch.tap()
        openLog(named: "A test journal log")
        app.buttons["Edit log"].tap()
        let editEditor = app.textViews["What happened?"]
        editEditor.tap()
        editEditor.typeText(" updated")
        app.buttons["Update"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit log"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Delete log"].tap()
        app.buttons["Delete"].tap()
    }

    func testCategoryManagementAndImmediateCheckIn() {
        app.buttons["New log"].tap()
        app.textFields["Create a category"].tap()
        app.textFields["Create a category"].typeText("Testing")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Testing"].exists)
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("A tagged test")
        app.buttons["Testing"].tap()
        app.buttons["Save"].firstMatch.tap()
        openLog(named: "A tagged test")
        app.buttons["Check in now"].tap()
        app.buttons["Much better"].tap()
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Much better"].firstMatch.waitForExistence(timeout: 3))
    }

    func testDelayedCheckInCanBeScheduledAndAnsweredEarly() {
        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Schedule a reflection")
        app.buttons["Save"].firstMatch.tap()
        openLog(named: "Schedule a reflection")
        app.buttons["Check in later"].tap()
        app.buttons["Later today"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Reschedule"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Check In"].tap()
        XCTAssertTrue(app.buttons["Answer early"].waitForExistence(timeout: 3))
        app.buttons["Answer early"].tap()
        app.buttons["About the same"].tap()
        app.buttons["Save"].firstMatch.tap()
    }

    func testDemoHistoryTabNavigationAndPatternSourceLogs() {
        app.tabBars.buttons["Check In"].tap()
        XCTAssertTrue(app.buttons["Add history"].waitForExistence(timeout: 3))
        app.buttons["Add history"].tap()
        app.tabBars.buttons["Patterns"].tap()
        XCTAssertTrue(app.staticTexts["Patterns"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Choose category"].tap()
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Source logs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open source log"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Open source log"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit log"].waitForExistence(timeout: 3))
    }
}
