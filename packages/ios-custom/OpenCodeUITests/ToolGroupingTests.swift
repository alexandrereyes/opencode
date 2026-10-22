import XCTest

@MainActor final class ToolGroupingTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_GROUP_" + role])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)], timeout: 25), .completed)
    return app
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "groups-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func group(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-context:'")).firstMatch
  }
  func testConsecutiveStepsShareOneDisclosureAndRememberExpansion() throws {
    let app = try launch("FINISHED")
    let disclosure = group(app)
    XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
    XCTAssertEqual(disclosure.label, "Usou 11 · Glob, Ler, Grep e Shell")
    XCTAssertEqual(disclosure.value as? String, "Recolhido")
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-context:'")).count, 1)
    screenshot("collapsed")
    disclosure.tap()
    XCTAssertEqual(disclosure.value as? String, "Expandido")
    let transcript = app.collectionViews["conversation-transcript"]
    transcript.swipeDown(velocity: .slow)
    for _ in 0..<3 {
      if disclosure.isHittable { break }
      transcript.swipeDown(velocity: .slow)
    }
    screenshot("expanded")
    app.buttons["Voltar"].tap()
    let session = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Grupos — concluído'")).firstMatch
    app.revealSessionRow(session)
    session.tap()
    let remembered = group(app)
    XCTAssertTrue(remembered.waitForExistence(timeout: 15))
    XCTAssertEqual(remembered.value as? String, "Expandido")
    screenshot("remembered")
  }
  func testRunningToolRemainsInsideTheSameGroup() throws {
    let app = try launch("RUNNING")
    let disclosure = group(app)
    XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
    XCTAssertEqual(disclosure.label, "Usou 11 · Glob, Ler, Grep e Shell")
    XCTAssertEqual(disclosure.value as? String, "Expandido")
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Rodando printf' ")).firstMatch.waitForExistence(timeout: 10))
    screenshot("running")
  }
}
