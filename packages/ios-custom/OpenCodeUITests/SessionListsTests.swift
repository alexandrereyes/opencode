import XCTest

@MainActor final class SessionListsTests: XCTestCase {
  func testCompletionWaitsForTheEndOfTheListGesture() {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeCatalogSections", "-OpenCodeSessionListUpdates"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0000"].waitForExistence(timeout: 20))
    let list = app.collectionViews.firstMatch
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -100)),
      withVelocity: .slow, thenHoldForDuration: 1)
    let report = app.staticTexts["session-list-fixture-report"]
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == 'held=true applied=true running=false shift=0.0'"), object: report)], timeout: 10), .completed)
  }

  func testListPlaceAndSwitcherOpening() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeCatalogSections"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0000"].waitForExistence(timeout: 20))
    continueAfterFailure = true
    let row = app.buttons["session-row-ses_scroll_0008"]
    app.revealSessionRow(row)
    let before = row.frame.minY
    shot("list-before", app)
    row.tap()
    XCTAssertTrue(app.buttons["conversation-switcher"].waitForExistence(timeout: 15))
    shot("conversation-without-accessory", app)
    XCTAssertFalse(app.buttons["master-accessory"].isHittable)
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.buttons["conversation-switcher"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    // The original List shifted by the restored tab bar/accessory's 105 pt here.
    XCTAssertEqual(row.frame.minY, before, accuracy: 1)
    let returned = row.frame.minY
    app.openYou()
    app.showSessions()
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertEqual(row.frame.minY, returned, accuracy: 1, "opening and closing Você keeps the current passage")
    shot("list-return", app)
    row.tap()
    XCTAssertTrue(app.buttons["conversation-switcher"].waitForExistence(timeout: 15))
    app.buttons["conversation-switcher"].tap()
    let first = app.collectionViews["session-switcher-list"].buttons["session-section-attention"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertTrue(first.isHittable)
    XCTAssertGreaterThanOrEqual(first.frame.minY, app.textFields["switcher-search"].frame.maxY)
    shot("switcher-opening", app)
  }

  private func shot(_ name: String, _ app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
