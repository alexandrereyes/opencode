import XCTest

@MainActor final class ConversationMCPTests: XCTestCase {
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ mode: String = "conversation") throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeMCPFixture", mode]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    return app
  }
  private func shot(_ name: String) {
    let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    item.name = name + "-" + theme
    item.lifetime = .keepAlways
    add(item)
  }
  private func waitValue(_ element: XCUIElement, _ value: String) {
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 20), .completed)
  }
  private func panel(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["conversation-mcp-panel"].firstMatch }
  private func assertBefore(_ first: XCUIElement, _ second: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(first.frame.minY < second.frame.minY
      || (abs(first.frame.minY - second.frame.minY) < 1 && first.frame.minX < second.frame.minX), file: file, line: line)
  }
  @discardableResult private func keyboardSettled(_ app: XCUIApplication) throws -> XCUIElement {
    // Text injection can retain an offscreen keyboard in the simulator AX tree.
    // Resolve the visible keyboard afresh instead of keeping its first identity.
    var previous: [CGRect] = []
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let frame = app.keyboards.allElementsBoundByIndex.map(\.frame).first(where: { frame in
        return frame.height > 0 && frame.minY >= app.frame.minY && frame.maxY <= app.frame.maxY + 1
      }) else { previous = []; return false }
      let sample = [frame, app.textViews["conversation-composer"].frame]
      defer { previous = sample }
      return previous == sample
    }, object: nil)], timeout: 10), .completed)
    return try XCTUnwrap(app.keyboards.allElementsBoundByIndex.first {
      let frame = $0.frame
      return frame.height > 0 && frame.minY >= app.frame.minY && frame.maxY <= app.frame.maxY + 1
    })
  }
  func testPanelTogglesPendingAndPreservesComposerFocusTextAndHeight() throws {
    let app = try launch("pending")
    defer { app.terminate() }
    let pill = app.buttons["conversation-mcp-pill"]
    XCTAssertTrue(pill.waitForExistence(timeout: 20))
    XCTAssertEqual(pill.label, "MCPs, 1 de 5 conectados")
    let input = app.textViews["conversation-composer"]
    XCTAssertEqual(input.value as? String, "Meu rascunho com MCPs")
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    try keyboardSettled(app)
    let frame = input.frame
    shot("pill-closed")
    pill.tap()
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    let safari = app.switches["mcp-safari-devtools"]
    let computer = app.switches["mcp-codex-computer-use"]
    XCTAssertTrue(safari.waitForExistence(timeout: 5))
    assertBefore(safari, computer)
    XCTAssertEqual(input.frame.height, frame.height, accuracy: 1)
    XCTAssertEqual(input.frame.minY, frame.minY, accuracy: 1)
    shot("panel-open")
    let original = safari.frame
    safari.tap()
    waitValue(safari, "Conectando")
    XCTAssertFalse(safari.isEnabled)
    shot("toggle-pending")
    waitValue(safari, "Desativado")
    XCTAssertEqual(safari.frame.minY, original.minY, accuracy: 1)
    XCTAssertEqual(pill.label, "MCPs, 0 de 5 conectados")
    safari.tap()
    waitValue(safari, "Ativado")
    XCTAssertEqual(input.value as? String, "Meu rascunho com MCPs")
    // Real key taps prove retained focus without XCTest's temporary hardware-keyboard injection.
    try keyboardSettled(app).keys["x"].tap()
    XCTAssertEqual(input.value as? String, "Meu rascunho com MCPsx")
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.23))
    outside.tap()
    XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    try keyboardSettled(app).keys["y"].tap()
    XCTAssertEqual(input.value as? String, "Meu rascunho com MCPsxy")
    pill.tap()
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    app.collectionViews["conversation-transcript"].swipeDown()
    XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "Meu rascunho com MCPsxy")
    pill.tap()
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    app.collectionViews["conversation-transcript"].tap()
    XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
  }
  func testLoginFailureAndReopenOrdering() throws {
    let app = try launch()
    defer { app.terminate() }
    let pill = app.buttons["conversation-mcp-pill"]
    XCTAssertTrue(pill.waitForExistence(timeout: 20))
    pill.tap()
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    app.switches["mcp-playwright"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'app web'")).firstMatch.exists)
    app.switches["mcp-figma"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Não foi possível alterar figma'")).firstMatch.waitForExistence(timeout: 10))
    let computer = app.switches["mcp-codex-computer-use"]
    computer.tap()
    waitValue(computer, "Ativado")
    assertBefore(app.switches["mcp-safari-devtools"], computer)
    pill.tap()
    pill.tap()
    XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
    assertBefore(computer, app.switches["mcp-safari-devtools"])
  }
  func testNoPillForEmptyOrUnsupportedLocations() throws {
    for mode in ["empty", "unsupported"] {
      let app = try launch(mode)
      XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 20))
      XCTAssertFalse(app.buttons["conversation-mcp-pill"].exists)
      app.terminate()
    }
  }
  func testNewSessionUsesTheSameStableOrdering() throws {
    let app = try launch("new-session")
    defer { app.terminate() }
    let safari = app.switches["mcp-safari-devtools"]
    XCTAssertTrue(safari.waitForExistence(timeout: 20))
    let computer = app.switches["mcp-codex-computer-use"]
    assertBefore(safari, computer)
    let original = safari.frame
    shot("new-session-order")
    safari.tap()
    waitValue(safari, "Desativado")
    XCTAssertEqual(safari.frame.minY, original.minY, accuracy: 1)
    XCTAssertEqual(safari.frame.minX, original.minX, accuracy: 1)
    shot("new-session-stable-disabled")
    app.buttons["new-directory"].tap()
    XCTAssertTrue(app.buttons["new-create"].waitForExistence(timeout: 5))
    app.buttons["new-create"].tap()
    XCTAssertTrue(app.buttons["new-base"].waitForExistence(timeout: 5))
    assertBefore(computer, safari)
    app.buttons["new-directory"].tap()
    app.buttons["new-root"].tap()
    waitValue(safari, "Desativado")
    assertBefore(computer, safari)
    shot("new-session-reopened-order")
  }
  func testLiveOnlySafariDisconnectAndReconnect() throws {
    let env = ProcessInfo.processInfo.environment
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(env["OPENCODE_MCP_LIVE_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(env["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let pill = app.buttons["conversation-mcp-pill"]
    XCTAssertTrue(pill.waitForExistence(timeout: 30))
    shot("live-pill-closed")
    pill.tap()
    let safari = app.switches["mcp-safari-devtools"]
    XCTAssertTrue(safari.waitForExistence(timeout: 10))
    waitValue(safari, "Ativado")
    shot("live-panel-open")
    safari.tap()
    waitValue(safari, "Desativado")
    safari.tap()
    waitValue(safari, "Ativado")
    shot("live-safari-restored")
  }
}
