import XCTest

/// Prepared by `script/test-session-chips.py`: every root session is read except one in each of two later
/// repositories. `OPENCODE_TEST_CHIP_MANUAL` is the saved repository order, `OPENCODE_TEST_CHIP_UNREAD` the two
/// unread repositories (in manual order) and `OPENCODE_TEST_CHIP_SESSION` the title to read in the second one.
@MainActor final class SessionChipsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testUnreadChipShowsDotMovesUpAndClearsAfterReading() throws {
    continueAfterFailure = false
    let manual = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_MANUAL"]).split(separator: ",").map(String.init)
    let unread = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_UNREAD"]).split(separator: ",").map(String.init)
    let title = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    let chats = app.buttons["filter-chats"]
    XCTAssertTrue(chats.waitForExistence(timeout: 20))

    // Unread repositories first, in the saved order; then Chats and the rest, still in the saved order.
    let read = manual.filter { !unread.contains($0) }
    XCTAssertTrue(settled(app, order: unread + ["Chats"] + read))
    for name in manual {
      XCTAssertEqual(chip(name, app).label, unread.contains(name) ? name + ", com não lidas" : name)
    }
    XCTAssertEqual(chats.label, "Chats")
    shot("chips-unread")

    chip(unread[1], app).tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForExistence(timeout: 30))
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))

    // Reading the last unread session clears the dot; the chip returns to its saved place.
    XCTAssertTrue(settled(app, order: [unread[0], "Chats"] + manual.filter { $0 != unread[0] }))
    XCTAssertEqual(chip(unread[1], app).label, unread[1])
    // The active filter stays visible after moving.
    let selected = chip(unread[1], app)
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in selected.frame.minX >= 0 && selected.frame.maxX <= app.frame.maxX + 1 },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Selected chip off screen")
    shot("chips-after-reading")
    app.buttons["Todas"].firstMatch.tap()
  }

  private func chip(_ name: String, _ app: XCUIApplication) -> XCUIElement {
    name == "Chats" ? app.buttons["filter-chats"] : app.buttons["filter-project-" + name]
  }
  /// Chip frames in the horizontal strip, compared left to right once the reorder animation settles.
  private func settled(_ app: XCUIApplication, order: [String]) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let elements = order.map { self.chip($0, app) }
        guard elements.allSatisfy(\.exists) else { return false }
        let positions = elements.map(\.frame.minX)
        return zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
      }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: 30) == .completed
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
