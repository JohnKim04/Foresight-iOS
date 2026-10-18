import XCTest

@MainActor
final class ForesightUITests: XCTestCase {
    // Set once in setUp, before any test reads it.
    nonisolated(unsafe) private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // XCTest's setUp isn't main-actor isolated, but it runs on the main thread.
        app = MainActor.assumeIsolated {
            let app = XCUIApplication()
            app.launchArguments = ["-in-memory-store", "-hasCompletedOnboarding", "YES"]
            app.launch()
            return app
        }
    }

    /// Saves the new-log editor, then leaves the post-log check-in step without answering.
    private func saveNewLog() {
        app.buttons["Save"].firstMatch.tap()
        let done = app.buttons["post-log.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
    }

    /// Loads the Debug-only sample history from Settings, then closes Settings on the Journal tab.
    private func addSampleHistory() {
        app.tabBars.buttons["Journal"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let add = app.buttons["settings.sample-history"]
        scrollSettings(until: add)
        XCTAssertEqual(add.label, "Add history")
        add.tap()
        XCTAssertTrue(app.staticTexts["Sample history added."].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
    }

    /// Scrolls the Settings form by dragging from near its bottom edge, below the quiet-hours
    /// wheels, so the drag scrolls the form instead of turning a wheel.
    private func scrollSettings(until element: XCUIElement) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
            start.press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
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

    func testSettingsShowsNotificationChoicesAndErasesTheJournal() {
        app.buttons["New log"].tap()
        let editor = app.textViews["What happened?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("A log to erase")
        saveNewLog()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A log to erase")).firstMatch.waitForExistence(timeout: 3))

        app.buttons["Settings"].tap()
        for title in ["Check-in reminders", "Pattern nudges", "Quiet hours"] {
            XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout: 3), "\(title) toggle is missing")
        }
        // The quiet-hours wheels and Categories push the data rows below the fold.
        let export = app.buttons["settings.export"]
        scrollSettings(until: export)
        XCTAssertTrue(export.exists)
        let erase = app.buttons["settings.erase"]
        scrollSettings(until: erase)
        erase.tap()
        let confirm = app.alerts.buttons["Erase"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Your journal was erased."].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A log to erase")).firstMatch.waitForExistence(timeout: 1))
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
        XCTAssertTrue(app.buttons["Testing"].waitForExistence(timeout: 3))
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("A tagged test")
        // Add already selected the new category, so the log is saved with it.
        saveNewLog()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "A tagged test", "Testing")).firstMatch.waitForExistence(timeout: 3))
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
        app.buttons["Same"].tap()
        app.buttons["Save"].firstMatch.tap()
    }

    func testDemoHistoryTabNavigationAndPatternSourceLogs() {
        addSampleHistory()
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
        addSampleHistory()
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

    func testJournalShowsTheTopSuggestionUntilHiddenForToday() {
        // A new journal has nothing confident to suggest, so Journal stays quiet.
        XCTAssertTrue(app.staticTexts["Notice what follows."].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["journal.suggestion"].exists)
        addSampleHistory()
        // Demo history: Workout, Sleep and Social were mostly better later.
        let suggestion = app.buttons["journal.suggestion"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        let category = ["Workout", "Sleep", "Social"].first { suggestion.label == "See the \($0) pattern" }
        XCTAssertNotNil(category, suggestion.label)
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["Source logs"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Choose category"].value as? String, category)

        app.tabBars.buttons["Journal"].tap()
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        app.buttons["journal.suggestion.hide"].tap()
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 2))
    }

    /// Types into the new-log editor, tapping it again if a tap during the cover's slide-in
    /// didn't give it keyboard focus.
    private func typeLog(_ text: String) {
        let editor = app.textViews["What happened?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        for _ in 0..<3 where !((editor.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) { editor.tap() }
        editor.typeText(text)
    }

    /// Opens the Journal's Filter sheet.
    private func openJournalFilters() {
        let filter = app.buttons["journal.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        filter.tap()
        XCTAssertTrue(app.staticTexts["Filter logs"].waitForExistence(timeout: 3))
    }

    func testJournalDropdownsSelectAndDismissEachOther() {
        // The Filter button appears once the journal has a log.
        XCTAssertFalse(app.buttons["journal.filter"].exists)
        app.buttons["New log"].tap()
        typeLog("A log to filter")
        saveNewLog()

        // The filters live behind one button, so the logs come first.
        let log = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A log to filter")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 3), "The new log should show before any filter")
        XCTAssertTrue(app.buttons["journal.filter"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Choose category"].exists)
        XCTAssertTrue(app.staticTexts["Last 30 days"].exists)
        openJournalFilters()

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

        // Tapping elsewhere in the sheet closes the open panel.
        category.tap()
        XCTAssertTrue(app.buttons["All categories"].waitForExistence(timeout: 2))
        app.staticTexts["DATES"].tap()
        XCTAssertFalse(app.buttons["All categories"].waitForExistence(timeout: 1))

        checkIn.tap()
        app.buttons["Scheduled"].tap()
        XCTAssertEqual(checkIn.value as? String, "Scheduled")
        XCTAssertTrue(app.staticTexts["0 logs match."].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()

        // A chip shows the active filter, and removing it brings the log back.
        let chip = app.buttons["Remove Check-in scheduled filter"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No matching logs"].exists)
        XCTAssertTrue(app.buttons["Clear filters"].exists)
        chip.tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 3), "Tapping the chip should remove its filter")
        XCTAssertTrue(app.staticTexts["Last 30 days"].waitForExistence(timeout: 3))
        XCTAssertTrue(log.waitForExistence(timeout: 3), "The log should come back once the filter is removed")
    }

    func testJournalCategoryDropdownUpdatesTheFilter() {
        app.buttons["New log"].tap()
        app.textFields["Create a category"].tap()
        app.textFields["Create a category"].typeText("Dropdown test")
        app.buttons["Add"].tap()
        typeLog("Only this category should match")
        saveNewLog()

        app.buttons["New log"].tap()
        typeLog("Uncategorized log")
        saveNewLog()

        let matching = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Only this category should match")).firstMatch
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Uncategorized log")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 3))

        openJournalFilters()
        let category = app.buttons["Choose category"]
        category.tap()
        app.buttons["Dropdown test"].tap()
        XCTAssertEqual(category.value as? String, "Dropdown test")
        XCTAssertTrue(app.staticTexts["1 log matches."].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Remove Dropdown test filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(matching.waitForExistence(timeout: 3))
        XCTAssertTrue(other.waitForNonExistence(timeout: 3), "Logs outside the selected category should be filtered out")

        // Reset in the sheet clears every filter at once.
        openJournalFilters()
        app.buttons["Reset"].tap()
        XCTAssertEqual(category.value as? String, "All categories")
        app.buttons["Done"].tap()
        XCTAssertTrue(other.waitForExistence(timeout: 3))
    }

    func testPatternsIsOneScreenWithWeeklyCounts() {
        addSampleHistory()
        app.tabBars.buttons["Patterns"].tap()

        let category = app.buttons["Choose category"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Activity"].exists, "Patterns no longer has an Activity mode")
        category.tap()
        app.buttons["Workout"].tap()
        XCTAssertEqual(category.value as? String, "Workout")
        XCTAssertTrue(app.staticTexts["Workout logs per week"].waitForExistence(timeout: 3))
    }

    func testCheckInSourceLogDoesNotOpenFromOutsideCard() {
        addSampleHistory()
        app.tabBars.buttons["Check In"].tap()

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
        XCTAssertTrue(app.staticTexts["Spot what repeats."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Write your first log"].exists)
        app.buttons["Look around first"].tap()
        XCTAssertTrue(app.buttons["New log"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textViews["What happened?"].exists)

        app.terminate()
        app.launchArguments = ["-in-memory-store"]
        app.launch()
        XCTAssertTrue(app.buttons["New log"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Write your first log"].exists)
        XCTAssertFalse(app.buttons["Next"].exists)
    }

    func testOnboardingEndsInTheFirstLog() {
        app.terminate()
        app.launchArguments = ["-in-memory-store", "-reset-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 3))
        for _ in 0..<3 { app.buttons["Next"].tap() }
        XCTAssertTrue(app.buttons["Write your first log"].waitForExistence(timeout: 3))
        app.buttons["Write your first log"].tap()
        XCTAssertTrue(app.textViews["What happened?"].waitForExistence(timeout: 5))
    }

    func testSavingALogAsksHowYouFeelAndSchedulesALaterCheckIn() {
        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("Went for an evening run")
        app.buttons["Save"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["How do you feel right now?"].waitForExistence(timeout: 3))
        app.buttons["Better"].tap()
        XCTAssertTrue(app.staticTexts["Saved: better"].waitForExistence(timeout: 2))
        app.buttons["In 2 hours"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Check-in set for")).firstMatch.waitForExistence(timeout: 2))
        app.buttons["post-log.done"].tap()

        openLog(named: "Went for an evening run")
        XCTAssertTrue(app.staticTexts["Better"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reschedule"].exists)
        app.tabBars.buttons["Check In"].tap()
        XCTAssertTrue(app.buttons["Answer early"].waitForExistence(timeout: 3))
    }

    func testAWorseRatingAfterSavingShowsAPatternFollowedByFeelingBetter() {
        addSampleHistory()
        app.buttons["New log"].tap()
        app.textViews["What happened?"].tap()
        app.textViews["What happened?"].typeText("A rough afternoon")
        app.buttons["Save"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["How do you feel right now?"].waitForExistence(timeout: 3))
        // Demo history has Workout, Sleep and Social mostly better later.
        let suggestion = app.buttons["post-log.suggestion"]
        XCTAssertFalse(suggestion.exists)
        app.buttons["Worse"].tap()
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        app.buttons["Same"].tap()
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 2))
        app.buttons["Much worse"].tap()
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        if !suggestion.isHittable { app.swipeUp() }
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["Source logs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Patterns"].isSelected)
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
        addSampleHistory()
        let tab = app.tabBars.buttons["Check In"]
        tab.tap()
        // Sample history has two later check-ins already past due.
        // iOS 27 exposes the badge as the tab button's value, e.g. "2 items". iOS 26.x
        // (CI's iOS 26.5 simulator) leaves the button's value empty, so UI tests can't read the badge;
        // there the test checks the same due count on the Check In screen instead.
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) {
            let badged = NSPredicate(format: "value MATCHES %@", "^2( items?)?$")
            expectation(for: badged, evaluatedWith: tab)
            waitForExpectations(timeout: 3)
        } else {
            let overdue = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Overdue since"))
            XCTAssertTrue(overdue.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(overdue.count, 2)
        }
    }
}
