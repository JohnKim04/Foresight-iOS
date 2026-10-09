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
        let log = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 3))
        log.tap()
    }

    func testFreshLaunchShowsJournal() {
        XCTAssertTrue(app.staticTexts["Notice what follows."].firstMatch.waitForExistence(timeout: 3))
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

    func testJournalEntryOpensOnlyFromItsCard() {
        app.buttons["New log"].tap()
        let editor = app.textViews["What happened?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Tap target test log")
        app.buttons["Save"].firstMatch.tap()

        let log = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tap target test log")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 3))
        let outsideCard = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 8, dy: log.frame.midY))
        outsideCard.tap()
        XCTAssertFalse(app.buttons["Edit log"].waitForExistence(timeout: 1), "Tapping the margin outside a journal card should not open it")

        app.buttons["Calendar"].tap()
        let calendarLog = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tap target test log")).firstMatch
        XCTAssertTrue(calendarLog.waitForExistence(timeout: 3))
        let outsideCalendarCard = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 8, dy: calendarLog.frame.midY))
        outsideCalendarCard.tap()
        XCTAssertFalse(app.buttons["Edit log"].waitForExistence(timeout: 1), "Tapping beside a calendar log card should not open it")

        calendarLog.tap()
        XCTAssertTrue(app.buttons["Edit log"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.staticTexts["See what repeats."].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Choose category"].tap()
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Source logs"].waitForExistence(timeout: 3))
        let source = app.buttons["Open source log"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        let outsideCard = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 8, dy: source.frame.midY))
        outsideCard.tap()
        XCTAssertFalse(app.buttons["Edit log"].waitForExistence(timeout: 1))
        source.tap()
        XCTAssertTrue(app.buttons["Edit log"].waitForExistence(timeout: 3))
    }

    func testJournalDropdownsSelectAndDismissEachOther() {
        let category = app.buttons["Choose category"]
        let checkIn = app.buttons["Choose check-in filter"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        XCTAssertTrue(checkIn.exists)

        category.tap()
        XCTAssertTrue(app.buttons["All categories"].waitForExistence(timeout: 2))
        // Tapping another trigger replaces the open panel instead of stacking it.
        checkIn.tap()
        XCTAssertTrue(app.buttons["Scheduled"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["All categories"].exists)
        checkIn.tap()
        XCTAssertFalse(app.buttons["Scheduled"].exists)

        // Tapping elsewhere on the screen closes the open panel.
        category.tap()
        XCTAssertTrue(app.buttons["All categories"].waitForExistence(timeout: 2))
        app.staticTexts["Notice what follows."].tap()
        XCTAssertFalse(app.buttons["All categories"].waitForExistence(timeout: 1))

        checkIn.tap()
        app.buttons["Scheduled"].tap()
        XCTAssertEqual(checkIn.value as? String, "Scheduled")
    }

    func testJournalCategoryDropdownUpdatesTheFilter() {
        app.buttons["New log"].tap()
        app.textFields["Create a category"].tap()
        app.textFields["Create a category"].typeText("Dropdown test")
        app.buttons["Add"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Only this category should match")
        app.buttons["Save"].firstMatch.tap()

        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Uncategorized log")
        app.buttons["Save"].firstMatch.tap()

        let matching = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Only this category should match")).firstMatch
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Uncategorized log")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 3))

        let category = app.buttons["Choose category"]
        category.tap()
        app.buttons["Dropdown test"].tap()
        XCTAssertEqual(category.value as? String, "Dropdown test")
        XCTAssertTrue(matching.waitForExistence(timeout: 3))
        XCTAssertTrue(other.waitForNonExistence(timeout: 3), "Logs outside the selected category should be filtered out")
    }

    func testPatternsActivityDropdownUpdatesSelection() {
        app.tabBars.buttons["Check In"].tap()
        app.buttons["Add history"].tap()
        app.tabBars.buttons["Patterns"].tap()
        app.buttons["Activity"].tap()

        let category = app.buttons["Choose category"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        category.tap()
        app.buttons["Workout"].tap()
        XCTAssertEqual(category.value as? String, "Workout")
    }

    func testCheckInSourceLogDoesNotOpenFromOutsideCard() {
        app.tabBars.buttons["Check In"].tap()
        app.buttons["Add history"].tap()

        let source = app.staticTexts["Went out for drinks and stayed later than I planned."].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where source.frame.midY > app.frame.height - 200 { scroll.swipeUp() }
        XCTAssertTrue(source.isHittable)

        let outsideCard = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 8, dy: source.frame.midY))
        outsideCard.tap()
        XCTAssertFalse(app.buttons["Edit log"].waitForExistence(timeout: 1))
    }
}
