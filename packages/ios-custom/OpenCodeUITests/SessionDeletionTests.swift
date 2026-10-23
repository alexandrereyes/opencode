import XCTest

@MainActor final class SessionDeletionTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func id(_ role: String) throws -> String {
    try XCTUnwrap(environment["OPENCODE_DELETE_" + role])
  }
  private func launch(_ session: String? = nil, failure: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    if let session { app.launchArguments += ["-OpenCodeOpenSession", session] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    if let failure { app.launchEnvironment["OPENCODE_TEST_DELETE_FAILURE"] = failure }
    app.launch()
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "delete-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func confirm(_ app: XCUIApplication) {
    let alert = app.alerts["Excluir sessão"]
    XCTAssertTrue(alert.waitForExistence(timeout: 8))
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'todas as suas sessões filhas' AND label CONTAINS 'não pode ser desfeito'")).firstMatch.exists)
    alert.buttons["Excluir sessão"].tap()
  }
  private func waitGone(_ element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)], timeout: 30), .completed)
  }
  func testSwipeCancelAndDeleteFamily() throws {
    let session = try id("SWIPE")
    let app = try launch()
    defer { app.terminate() }
    let row = app.buttons["session-row-" + session]
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 30))
    app.revealSessionRow(row)
    XCTAssertTrue(row.exists)
    row.swipeLeft()
    shot("swipe")
    XCTAssertFalse(app.alerts["Excluir sessão"].exists)
    app.buttons["Excluir"].tap()
    XCTAssertTrue(app.alerts["Excluir sessão"].waitForExistence(timeout: 5))
    shot("confirmation")
    app.alerts.buttons["Cancelar"].tap()
    XCTAssertTrue(row.exists)
    row.swipeLeft()
    app.buttons["Excluir"].tap()
    confirm(app)
    waitGone(row)
    shot("deleted-list")
  }
  func testConversationMenuReturnsToSessions() throws {
    let app = try launch(id("MENU"))
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    app.buttons["Mais opções"].tap()
    XCTAssertTrue(app.buttons["Excluir sessão"].waitForExistence(timeout: 5))
    shot("menu")
    app.buttons["Excluir sessão"].tap()
    confirm(app)
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["session-row-" + (try id("MENU"))].exists)
    shot("menu-return")
  }
  func testServerFailureKeepsConversationAndRow() throws {
    let session = try id("FAILURE")
    let app = try launch(session, failure: session)
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    app.buttons["Mais opções"].tap()
    app.buttons["Excluir sessão"].tap()
    confirm(app)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Falha ao excluir sessão.'")).firstMatch.waitForExistence(timeout: 15))
    XCTAssertTrue(app.collectionViews["conversation-transcript"].exists)
    shot("failure")
    app.buttons["Voltar"].tap()
    app.revealSessionRow(app.buttons["session-row-" + session])
    XCTAssertTrue(app.buttons["session-row-" + session].waitForExistence(timeout: 20))
  }
  func testArchivedContextMenuDeletion() throws {
    let app = try launch()
    defer { app.terminate() }
    let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Arquivadas'")).firstMatch
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 30))
    app.revealSessionRow(button)
    XCTAssertTrue(button.exists)
    button.tap()
    XCTAssertTrue(app.navigationBars["Arquivadas"].waitForExistence(timeout: 10))
    let row = app.buttons["archived-row-" + (try id("ARCHIVED"))]
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.press(forDuration: 1)
    app.buttons["Excluir sessão"].tap()
    confirm(app)
    waitGone(row)
    shot("archived")
  }
}
