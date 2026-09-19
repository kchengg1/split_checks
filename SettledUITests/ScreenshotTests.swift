import XCTest

/// Captures App Store screenshots by driving the app (seeded with demo data
/// via the UITEST_SCREENSHOTS launch argument) and attaching a full-screen
/// image at each stop. The screenshots workflow exports these attachments.
final class ScreenshotTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureScreenshots() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_SCREENSHOTS"]
        app.launch()

        // 1) Receipt tab (the default) showing a scanned, itemized bill.
        XCTAssertTrue(app.tabBars.buttons["Groups"].waitForExistence(timeout: 20))
        capture("01-receipt")

        // 2) Groups list with the overall "you owe / you are owed" header.
        app.tabBars.buttons["Groups"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        capture("02-groups")

        // 3) A group's expenses and payments. The first cell is the overall
        // balance header, so open the trip by name. SwiftUI may expose the
        // row as one combined element, so match on the label, any type.
        let lisbon = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Lisbon Trip"))
            .firstMatch
        XCTAssertTrue(lisbon.waitForExistence(timeout: 10))
        lisbon.tap()
        XCTAssertTrue(app.buttons["Balances"].waitForExistence(timeout: 10))
        capture("03-expenses")

        // 4) Balances and settle-up.
        app.buttons["Balances"].tap()
        capture("04-settle-up")

        // 5) One expense in detail: a two-payer dinner with an adjustment.
        app.buttons["Expenses"].tap()
        let dinner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Seafood dinner"))
            .firstMatch
        XCTAssertTrue(dinner.waitForExistence(timeout: 10))
        dinner.tap()
        XCTAssertTrue(app.navigationBars["Seafood dinner"].waitForExistence(timeout: 10))
        capture("06-expense-detail")
        app.navigationBars.buttons.firstMatch.tap()

        // 6) An itemized expense from a scanned receipt.
        let tasca = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Tasca do Chico"))
            .firstMatch
        XCTAssertTrue(tasca.waitForExistence(timeout: 10))
        tasca.tap()
        XCTAssertTrue(app.navigationBars["Tasca do Chico"].waitForExistence(timeout: 10))
        capture("07-itemized-expense")
        app.navigationBars.buttons.firstMatch.tap()

        // 7) Friends: what everyone owes you across groups.
        app.tabBars.buttons["Friends"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        capture("08-friends")

        // 5) The cross-group activity feed.
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        capture("05-activity")
    }

    private func capture(_ name: String) {
        // Let SwiftUI finish any transition before grabbing the frame.
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
