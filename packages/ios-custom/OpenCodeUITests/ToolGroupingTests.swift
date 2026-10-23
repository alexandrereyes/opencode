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
    let disclosureID = disclosure.identifier
    XCTAssertEqual(disclosure.label, "Usou 33 · Patch, Shell, Ler e Grep")
    XCTAssertEqual(disclosure.value as? String, "Recolhido")
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-context:'")).count, 1)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity-file-'")).firstMatch.exists)
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
    let file = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity-file-'")).firstMatch
    XCTAssertTrue(file.exists)
    XCTAssertEqual(file.value as? String, "Recolhido")
    file.tap()
    XCTAssertEqual(file.value as? String, "Expandido")
    screenshot("diff")
    app.buttons["Voltar"].tap()
    let session = app.buttons["session-row-" + (try XCTUnwrap(environment["OPENCODE_TEST_GROUP_FINISHED"]))]
    app.revealSessionRow(session)
    session.tap()
    let remembered = group(app)
    XCTAssertTrue(remembered.waitForExistence(timeout: 15))
    XCTAssertEqual(remembered.identifier, disclosureID)
    XCTAssertEqual(remembered.value as? String, "Expandido")
    screenshot("remembered")
  }
  func testRunningToolRemainsInsideTheSameGroup() throws {
    let app = try launch("RUNNING")
    let disclosure = group(app)
    XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
    XCTAssertEqual(disclosure.label, "Usou 33 · Patch, Shell, Ler e Grep")
    XCTAssertEqual(disclosure.value as? String, "Recolhido")
    screenshot("running")
    disclosure.tap()
    XCTAssertEqual(disclosure.value as? String, "Expandido")
    let transcript = app.collectionViews["conversation-transcript"]
    transcript.swipeDown(velocity: .slow)
    screenshot("running-expanded")
    let failed = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Falha de exemplo'")).firstMatch
    for _ in 0..<8 {
      if failed.isHittable { break }
      transcript.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(failed.isHittable)
    failed.tap()
    XCTAssertTrue(app.staticTexts["Falha de exemplo"].exists)
    screenshot("failed")
  }
}
