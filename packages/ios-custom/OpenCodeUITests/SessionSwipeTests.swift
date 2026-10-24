import XCTest

/// Needs two owned sessions from `script/test-session-swipe.py`: the target and a more recent unpinned anchor.
@MainActor final class SessionSwipeTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "swipe-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testTrailingSwipePinsAndUnpins() throws {
    let target = try XCTUnwrap(environment["OPENCODE_SWIPE_TARGET"])
    let anchor = try XCTUnwrap(environment["OPENCODE_SWIPE_ANCHOR"])
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let row = app.buttons["session-row-" + target]
    let other = app.buttons["session-row-" + anchor]
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 30))
    app.revealSessionRow(row)
    XCTAssertFalse(row.label.contains(", fixada"))
    assertBelowAnchor(row, other)

    row.swipeLeft()
    XCTAssertTrue(app.buttons["Fixar"].waitForExistence(timeout: 5))
    for action in ["Silenciar", "Arquivar", "Excluir"] { XCTAssertTrue(app.buttons[action].exists, action) }
    XCTAssertFalse(app.buttons["Mais"].exists)
    XCTAssertFalse(app.buttons["Abrir sessão"].exists)
    let order = ["Silenciar", "Arquivar", "Fixar", "Excluir"].map { app.buttons[$0].frame.minX }
    XCTAssertEqual(order, order.sorted())
    shot("actions")
    app.buttons["Fixar"].tap()
    wait(row, label: ", fixada", present: true)
    app.revealSessionRow(row)
    XCTAssertTrue(!other.exists || other.frame.minY >= row.frame.maxY, "A fixada deve subir acima das não fixadas.")
    let above = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).allElementsBoundByIndex
      .filter { $0.identifier != row.identifier && $0.frame.maxY <= row.frame.minY }
    XCTAssertTrue(above.allSatisfy { $0.label.contains(", fixada") }, "Só sessões fixadas podem ficar acima.")
    shot("pinned")

    row.swipeLeft()
    XCTAssertTrue(app.buttons["Desafixar"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Mais"].exists)
    app.buttons["Desafixar"].tap()
    wait(row, label: ", fixada", present: false)
    app.revealSessionRow(row)
    assertBelowAnchor(row, other)
    shot("unpinned")
  }

  private func assertBelowAnchor(_ row: XCUIElement, _ anchor: XCUIElement) {
    XCTAssertTrue(anchor.exists, "A âncora mais recente deve estar logo acima.")
    XCTAssertLessThanOrEqual(anchor.frame.maxY, row.frame.minY)
  }

  private func wait(_ row: XCUIElement, label: String, present: Bool) {
    let predicate = NSPredicate(format: present ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", label)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: row)], timeout: 10), .completed)
  }
}
