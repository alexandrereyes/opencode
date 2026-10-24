import XCTest

/// Requires `OPENCODE_AGENTS_PARENT` with direct children listed newest start first in `OPENCODE_AGENTS_ORDER`:
/// interrupted, failed, running (`OPENCODE_AGENTS_RUNNING`) and succeeded (`script/test-agents-screen.py`).
@MainActor final class ConversationAgentsTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "agents-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.buttons["agent-work-" + id] }

  func testRunningAndFinishedShareOneScreenAndNavigationReturnsThroughIt() throws {
    let order = try XCTUnwrap(environment["OPENCODE_AGENTS_ORDER"]).split(separator: ",").map(String.init)
    let running = try XCTUnwrap(environment["OPENCODE_AGENTS_RUNNING"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_AGENTS_PARENT"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    let agents = app.buttons["conversation-agents"]
    XCTAssertTrue(agents.waitForExistence(timeout: 30))
    XCTAssertEqual(agents.label, "1 agente em execução")
    screenshot("conversation")

    // A pushed screen with a back button, not a sheet with a grabber and Concluir.
    agents.tap()
    let bar = app.navigationBars["Agentes e tarefas"]
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    XCTAssertTrue(bar.buttons.element(boundBy: 0).exists)
    XCTAssertFalse(app.buttons["Concluir"].exists)
    let rows = order.map { row(app, $0) }
    XCTAssertTrue(rows.allSatisfy { $0.waitForExistence(timeout: 20) })
    XCTAssertEqual(rows.map(\.frame.minY), rows.map(\.frame.minY).sorted(), "newest start first, running not promoted")
    XCTAssertEqual(rows.map { $0.value as? String }, ["Interrompido", "Erro", "Em execução", "Concluído"])
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Parar '")).count, 1)
    XCTAssertTrue(app.buttons["Parar Executar verificação longa"].exists)
    screenshot("list")

    // A finished child opens; Back returns to the list, then to the conversation.
    rows[3].tap()
    let title = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    XCTAssertEqual(title.label, "Mapear dependências")
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 20))
    screenshot("child")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    XCTAssertTrue(row(app, running).waitForExistence(timeout: 10))
    screenshot("list-after-child")
    bar.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(agents.waitForExistence(timeout: 10))
    XCTAssertFalse(bar.exists)
    XCTAssertEqual(title.label, "Agentes e tarefas")

    // A running child: "Voltar à sessão principal" skips the list and lands on the parent conversation.
    agents.tap()
    XCTAssertTrue(row(app, running).waitForExistence(timeout: 10))
    row(app, running).tap()
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 20))
    XCTAssertEqual(title.label, "Executar verificação longa")
    app.buttons["Voltar à sessão principal"].tap()
    XCTAssertTrue(agents.waitForExistence(timeout: 10))
    XCTAssertFalse(bar.exists)
    XCTAssertEqual(title.label, "Agentes e tarefas")
    screenshot("back-to-conversation")
  }
}
