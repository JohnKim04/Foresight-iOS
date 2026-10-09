import XCTest

@MainActor
final class ForesightUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-in-memory-store", "-hasCompletedOnboarding", "YES"]
        app.launch()
    }

    /// Saves the new-log editor, then leaves the post-log check-in step without answering.
    private func saveNewLog() {
        app.buttons["Save"].firstMatch.tap()
        let done = app.buttons["post-log.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
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
            "-hasCompletedOnboarding", "YES",
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
        saveNewLog()
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
        saveNewLog()

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
        saveNewLog()
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
        saveNewLog()
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

    func testPatternsSuggestsWhatHasTendedToHelp() {
        app.tabBars.buttons["Patterns"].tap()
        XCTAssertTrue(app.staticTexts["OFTEN FOLLOWED BY FEELING BETTER"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["See Workout later evidence"].exists)
        app.tabBars.buttons["Check In"].tap()
        XCTAssertTrue(app.buttons["Add history"].waitForExistence(timeout: 3))
        app.buttons["Add history"].tap()
        app.tabBars.buttons["Patterns"].tap()
        // Demo history: Workout, Sleep and Social were mostly better later. Alcohol felt
        // better right after but worse later, and Scrolling and Work have no clear lift.
        let suggestion = app.buttons["See Workout later evidence"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        for name in ["Sleep", "Social"] { XCTAssertTrue(app.buttons["See \(name) later evidence"].exists, name) }
        for name in ["Alcohol", "Scrolling", "Work"] { XCTAssertFalse(app.buttons["See \(name) later evidence"].exists, name) }
        suggestion.tap()
        XCTAssertEqual(app.buttons["Choose category"].value as? String, "Workout")
        XCTAssertTrue(app.staticTexts["Source logs"].waitForExistence(timeout: 3))
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
        saveNewLog()

        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Uncategorized log")
        saveNewLog()

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

    func testFirstLaunchShowsOnboardingOnce() {
        app.terminate()
        app.launchArguments = ["-in-memory-store", "-reset-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 3))
        for _ in 0..<3 { app.buttons["Next"].tap() }
        XCTAssertTrue(app.staticTexts["See what tends to help."].waitForExistence(timeout: 3))
        app.buttons["Start journaling"].tap()
        XCTAssertTrue(app.buttons["New log"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["-in-memory-store"]
        app.launch()
        XCTAssertTrue(app.buttons["New log"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Start journaling"].exists)
        XCTAssertFalse(app.buttons["Next"].exists)
    }

    func testSavingALogAsksHowYouFeelAndSchedulesALaterCheckIn() {
        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Went for an evening run")
        app.buttons["Save"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["How do you feel right now?"].waitForExistence(timeout: 3))
        app.buttons["A little better"].tap()
        XCTAssertTrue(app.staticTexts["Saved: a little better"].waitForExistence(timeout: 2))
        app.buttons["In 2 hours"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Check-in set for")).firstMatch.waitForExistence(timeout: 2))
        app.buttons["post-log.done"].tap()

        openLog(named: "Went for an evening run")
        XCTAssertTrue(app.staticTexts["A little better"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reschedule"].exists)
        app.tabBars.buttons["Check In"].tap()
        XCTAssertTrue(app.buttons["Answer early"].waitForExistence(timeout: 3))
    }

    func testTappingAChosenLaterTimeAgainCancelsIt() {
        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Changed my mind about later")
        app.buttons["Save"].firstMatch.tap()
        let inTwoHours = app.buttons["In 2 hours"]
        XCTAssertTrue(inTwoHours.waitForExistence(timeout: 3))
        inTwoHours.tap()
        inTwoHours.tap()
        app.buttons["post-log.done"].tap()
        app.tabBars.buttons["Check In"].tap()
        XCTAssertFalse(app.buttons["Answer early"].waitForExistence(timeout: 1))
    }

    func testCheckInTabShowsABadgeForDueCheckIns() {
        let tab = app.tabBars.buttons["Check In"]
        tab.tap()
        app.buttons["Add history"].tap()
        // Sample history has two later check-ins already past due.
        // The tab bar exposes the badge as the button's value, e.g. "2 items".
        let badged = NSPredicate(format: "value MATCHES %@", "^2( items?)?$")
        sleep(3)
        print("CIDEBUG value=<\(String(describing: tab.value))> label=<\(tab.label)>")
        print("CIDEBUG tabbar=\(app.tabBars.firstMatch.debugDescription)")
        app.tabBars.buttons["Journal"].tap()
        sleep(2)
        for b in app.tabBars.buttons.allElementsBoundByIndex { print("CIDEBUG unselected \(b.label) value=<\(String(describing: b.value))>") }
        print("CIDEBUG tabbar2=\(app.tabBars.firstMatch.debugDescription)")
        tab.tap()
        sleep(1)
        print("CIDEBUG checkin-screen=\(app.debugDescription)")
        expectation(for: badged, evaluatedWith: tab)
        waitForExpectations(timeout: 3)
    }
}
