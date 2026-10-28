import XCTest

/// Needs a seed-sessions sandbox whose projects have icons: `OPENCODE_TEST_AVATAR_SVG` and `OPENCODE_TEST_AVATAR_PNG`
/// are `name=RRGGBB=sessionID` (a color the icon clearly shows; the SVG one's session running, the PNG one's unread),
/// `OPENCODE_TEST_AVATAR_PLAIN` is `name=sessionID` of a project without icon, and `OPENCODE_TEST_AVATAR_ARC` the
/// theme's success color (the running arc).
@MainActor final class ProjectAvatarTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testProjectIconsReplaceMonogramsUnderArcBadgesAndSelection() throws {
    continueAfterFailure = false
    let svg = try spec("SVG")
    let png = try spec("PNG")
    let plain = try spec("PLAIN")
    let arc = try XCTUnwrap(environment["OPENCODE_TEST_AVATAR_ARC"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    try app.requireSandbox()
    app.showSessions()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))

    // Rows: the icon replaces the monogram, under the running arc; a project without icon keeps its monogram.
    let running = row(svg[2], app)
    app.revealSessionRow(running)
    XCTAssertTrue(wait { running.pixels(near: svg[1], leading: 70) > 20 }, "SVG icon in the row")
    XCTAssertGreaterThan(running.pixels(near: arc, leading: 70), 5, "Running arc over the icon")
    shot("avatar-running")
    let unread = row(png[2], app)
    app.revealSessionRow(unread)
    XCTAssertTrue(unread.label.contains(", não lida"))
    XCTAssertTrue(wait { unread.pixels(near: png[1], leading: 70) > 20 }, "PNG icon in the row")
    let monogram = row(plain[1], app)
    app.revealSessionRow(monogram)
    XCTAssertEqual(monogram.pixels(near: svg[1], leading: 70), 0)
    XCTAssertEqual(monogram.pixels(near: png[1], leading: 70), 0)
    app.revealSessionRow(unread)
    shot("avatar-rows")

    // Batch selection adds its circle before the avatar, which keeps the icon (lime: the selection circle and the
    // unread dot are orange like the PNG icon).
    app.revealSessionRow(running)
    running.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Selecionar"].waitForExistence(timeout: 5))
    app.buttons["Selecionar"].tap()
    XCTAssertTrue(app.buttons["sessions-selection-done"].waitForExistence(timeout: 5))
    XCTAssertTrue(running.isSelected)
    XCTAssertGreaterThan(running.pixels(near: svg[1], leading: 110), 20, "Icon during selection")
    shot("avatar-selection")
    app.buttons["sessions-selection-done"].tap()
    XCTAssertTrue(app.buttons["sessions-selection-done"].waitForNonExistence(timeout: 5))
    app.revealSessionRow(unread)

    // The conversation header shows it inside the context ring.
    unread.tap()
    let header = app.buttons["conversation-header-avatar"]
    XCTAssertTrue(header.waitForExistence(timeout: 30))
    XCTAssertTrue(wait { header.pixels(near: png[1]) > 20 }, "Icon in the header")

    // So does the session switcher, through the same compact row.
    app.buttons["conversation-switcher"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText(svg[0])
    let switched = app.buttons["switcher-row-" + svg[2]]
    XCTAssertTrue(switched.waitForExistence(timeout: 10))
    XCTAssertTrue(wait { switched.pixels(near: svg[1], leading: 70) > 20 }, "SVG icon in the switcher")
    shot("avatar-switcher")
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: svg[0].count + 2) + plain[0])
    let other = app.buttons["switcher-row-" + plain[1]]
    XCTAssertTrue(other.waitForExistence(timeout: 10))
    XCTAssertEqual(other.pixels(near: svg[1], leading: 70), 0)
    XCTAssertEqual(other.pixels(near: png[1], leading: 70), 0)
    // While searching, the close button loses its identifier ("Fechar"); it may first just end the search.
    for _ in 0..<3 where search.exists {
      (app.buttons["switcher-close"].exists ? app.buttons["switcher-close"] : app.buttons["Fechar"].firstMatch).tap()
      _ = search.waitForNonExistence(timeout: 2)
    }
    XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    XCTAssertTrue(header.waitForExistence(timeout: 10))
    shot("avatar-header")
  }

  private func spec(_ name: String) throws -> [String] {
    try XCTUnwrap(environment["OPENCODE_TEST_AVATAR_" + name]).split(separator: "=").map(String.init)
  }
  private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(identifier: "session-row-" + id).firstMatch
  }
  private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
