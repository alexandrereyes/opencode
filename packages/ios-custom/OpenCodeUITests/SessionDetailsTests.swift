import XCTest

/// Requires `OPENCODE_DETAILS_SESSION`, whose transcript loaded the skills listed in order in
/// `OPENCODE_DETAILS_SKILLS`, the connected MCP `OPENCODE_DETAILS_MCP` and the plugin count `OPENCODE_DETAILS_PLUGINS`
/// in its Location (`script/test-session-details.py` prepares them).
@MainActor final class SessionDetailsTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "details-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ element: XCUIElement, value: String) {
    let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 30), .completed, "\(element.identifier) → \(value)")
  }
  private func reveal(_ app: XCUIApplication, _ element: XCUIElement, up: Bool = false) {
    for _ in 0..<15 {
      if element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 40 { return }
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.7))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.4))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTAssertTrue(element.isHittable, element.identifier)
  }

  func testSectionsOrderTogglesAndCollapsedLists() throws {
    let skills = try XCTUnwrap(environment["OPENCODE_DETAILS_SKILLS"]).split(separator: ",").map(String.init)
    let mcp = try XCTUnwrap(environment["OPENCODE_DETAILS_MCP"])
    let plugins = Int(environment["OPENCODE_DETAILS_PLUGINS"] ?? "") ?? 0
    XCTAssertGreaterThan(skills.count, 5, "the fixture must exercise the collapsed limit")
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_DETAILS_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["session-details-directory"].waitForExistence(timeout: 10))
    screenshot("top")

    // MCP starts expanded, with one live toggle per server driving the composer's own MCP state.
    let mcpHeader = app.buttons["session-details-mcp-header"]
    reveal(app, mcpHeader)
    let toggle = app.switches["session-details-mcp-" + mcp]
    XCTAssertTrue(toggle.waitForExistence(timeout: 20))
    reveal(app, toggle)
    wait(toggle, value: "Ativado")
    screenshot("mcp")
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    wait(toggle, value: "Desativado")
    screenshot("mcp-off")
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    wait(toggle, value: "Ativado")
    mcpHeader.tap()
    XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
    mcpHeader.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))

    // Skills list what this session loaded, collapsed to the first five in load order.
    let more = app.buttons["session-details-skills-more"]
    reveal(app, app.buttons["session-details-skills-header"])
    reveal(app, more)
    XCTAssertEqual(more.label, "Mostrar todos (\(skills.count))")
    let shown = skills.prefix(5).map { app.descendants(matching: .any)["session-details-skill-" + $0] }
    XCTAssertTrue(shown.allSatisfy(\.exists))
    XCTAssertEqual(shown.map(\.frame.minY), shown.map(\.frame.minY).sorted())
    XCTAssertFalse(app.descendants(matching: .any)["session-details-skill-" + skills[5]].exists)
    screenshot("skills-collapsed")
    more.tap()
    let last = app.descendants(matching: .any)["session-details-skill-" + skills[skills.count - 1]]
    XCTAssertTrue(last.waitForExistence(timeout: 5))
    reveal(app, more)
    XCTAssertEqual(more.label, "Mostrar menos")
    screenshot("skills-expanded")
    more.tap()
    XCTAssertTrue(last.waitForNonExistence(timeout: 5))

    // Plugins close the sheet, below Skills, and LSP is gone.
    let pluginsHeader = app.buttons["session-details-plugins-header"]
    reveal(app, pluginsHeader)
    reveal(app, more)
    XCTAssertGreaterThan(pluginsHeader.frame.minY, more.frame.maxY)
    let pluginsMore = app.buttons["session-details-plugins-more"]
    if plugins > 5 {
      reveal(app, pluginsMore)
      XCTAssertEqual(pluginsMore.label, "Mostrar todos (\(plugins))")
      screenshot("plugins-collapsed")
      pluginsMore.tap()
      reveal(app, pluginsMore)
      XCTAssertEqual(pluginsMore.label, "Mostrar menos")
      screenshot("plugins-expanded")
      pluginsMore.tap()
    } else {
      XCTAssertFalse(pluginsMore.exists)
    }
    for _ in 0..<4 { app.swipeUp() }
    screenshot("end")
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'LSP'")).firstMatch.exists)
    app.buttons["Fechar"].tap()
  }
}
