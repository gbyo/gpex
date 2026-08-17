import XCTest

/// A small number of end-to-end checks over the real UI.
///
/// The app is launched with `-GpExUITesting`, which swaps Core Location for a scripted
/// provider and the store for an in-memory one seeded with a single finished session.
/// That keeps these tests off GPS hardware and away from the system location alert,
/// which is what makes them worth running at all.
///
/// The class is nonisolated to match `XCTestCase`, while each test is `@MainActor`
/// because `XCUIElement` is. Every test builds its own `XCUIApplication` rather than
/// sharing one, so there is no state to carry between them.
final class GpExUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GpExUITesting"]
        app.launch()
        return app
    }

    // MARK: - Recording

    @MainActor
    func testIdleHomeScreenOffersStart() {
        let app = launchApp()

        XCTAssertTrue(app.navigationBars["PhotoTrack"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startRecording"].exists)
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
        XCTAssertTrue(app.staticTexts["Camera Clock"].exists)
        // The privacy promise sits on the first screen, not behind an onboarding flow.
        XCTAssertTrue(
            app.staticTexts["Tracks stay on this iPhone until you export or delete them."].exists
        )
    }

    @MainActor
    func testStartMovesToActiveRecordingScreen() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["startRecording"].waitForExistence(timeout: 10))
        app.buttons["startRecording"].tap()

        let headline = app.staticTexts["recordingHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["stopRecording"].exists)

        // The scripted fixes arrive within about a second and the status becomes honest.
        expectation(for: NSPredicate(format: "label == %@", "Recording"), evaluatedWith: headline)
        waitForExpectations(timeout: 15)

        XCTAssertTrue(
            app.staticTexts["Moving"].exists || app.staticTexts["Stationary"].exists,
            "The activity should be stated in words"
        )
        XCTAssertTrue(app.staticTexts["Locations"].exists)
    }

    @MainActor
    func testStopShowsCompletedSession() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["startRecording"].waitForExistence(timeout: 10))
        app.buttons["startRecording"].tap()

        let stop = app.buttons["stopRecording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()

        // Stopping goes straight to the finished session.
        XCTAssertTrue(app.textFields["sessionName"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recorded locations"].exists)
        XCTAssertTrue(app.buttons["deleteSession"].exists)
    }

    // MARK: - Session detail

    @MainActor
    func testEditSessionName() {
        let app = launchApp()
        openSeededSession(in: app)

        let field = app.textFields["sessionName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()

        // Clear the existing name, then type a new one and submit.
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("Football Homecoming\n")

        XCTAssertTrue(app.navigationBars["Football Homecoming"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSetClockCorrection() {
        let app = launchApp()
        openSeededSession(in: app)

        let correctionRow = app.buttons["cameraClockCorrection"]
        XCTAssertTrue(correctionRow.waitForExistence(timeout: 10))
        correctionRow.tap()

        XCTAssertTrue(app.navigationBars["Camera Clock Correction"].waitForExistence(timeout: 10))

        // Camera was five seconds slow.
        app.buttons["Slow"].tap()
        let seconds = app.steppers["correctionSeconds"]
        XCTAssertTrue(seconds.waitForExistence(timeout: 10))
        let increment = seconds.buttons.element(boundBy: 1)
        for _ in 0..<5 { increment.tap() }

        // The row exists from the moment the screen appears, so existence proves
        // nothing about the taps. Wait for the text itself to catch up.
        let summary = app.staticTexts["correctionSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Camera was 5 seconds slow"),
            evaluatedWith: summary
        )
        waitForExpectations(timeout: 10)
        XCTAssertTrue(summary.label.contains("Camera was 5 seconds slow"), summary.debugDescription)

        // The sign has to be unmistakable.
        let adjustment = app.staticTexts["exportAdjustment"]
        XCTAssertTrue(adjustment.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "−00:00:05"), evaluatedWith: adjustment)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(adjustment.value as? String, "−00:00:05")

        // And it survives a fresh read, meaning it was saved rather than just held in
        // the detail view that is already on screen. Pop all the way to the list and
        // reopen the session so the row comes from a new `@Query`. Relaunching would be
        // a stronger check but is not available here: the UI-testing store is in memory
        // and re-seeds its fixture on every launch.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["cameraClockCorrection"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["PhotoTrack"].waitForExistence(timeout: 10))

        openSeededSession(in: app)
        let savedRow = app.buttons["cameraClockCorrection"]
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10))
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Camera was 5 seconds slow"),
            evaluatedWith: savedRow
        )
        waitForExpectations(timeout: 10)
        XCTAssertTrue(savedRow.label.contains("Camera was 5 seconds slow"), savedRow.debugDescription)
    }

    @MainActor
    func testExportGPXBecomesAvailable() {
        let app = launchApp()
        openSeededSession(in: app)

        // The file is prepared asynchronously, then offered through the share sheet.
        XCTAssertTrue(
            app.buttons["Export GPX"].waitForExistence(timeout: 15),
            "Export GPX should be offered once the file is prepared"
        )
    }

    @MainActor
    func testDeleteSession() {
        let app = launchApp()
        openSeededSession(in: app)

        let delete = app.buttons["deleteSession"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        // Destructive actions are confirmed.
        let confirm = app.sheets.buttons["Delete Session"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(app.navigationBars["PhotoTrack"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Soccer vs Greenwood"].exists)
    }

    // MARK: - Camera clock

    @MainActor
    func testCameraClockShowsLocalAndUTCTime() {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Camera Clock"].waitForExistence(timeout: 10))
        app.staticTexts["Camera Clock"].tap()

        XCTAssertTrue(app.navigationBars["Camera Clock"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["CAMERA CLOCK"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Coordinated Universal Time")).firstMatch.exists,
            "The UTC time and offset should both be shown"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func openSeededSession(in app: XCUIApplication) {
        let session = app.staticTexts["Soccer vs Greenwood"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
    }
}
