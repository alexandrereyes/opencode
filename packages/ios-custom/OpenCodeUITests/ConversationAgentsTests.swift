import XCTest

/// Requires `OPENCODE_AGENTS_PARENT` with direct children in `OPENCODE_AGENTS_ORDER` (running first, then by
/// latest activity): a real running delegation (`OPENCODE_AGENTS_DELEGATED`, whose reloaded running call has no
/// child ID), a background subagent (`OPENCODE_AGENTS_BACKGROUND`), an old child resumed now
/// (`OPENCODE_AGENTS_RUNNING`), then interrupted, failed and succeeded; the parent also runs one background
/// script (`OPENCODE_AGENTS_SCRIPT`)
/// (`script/test-agents-screen.py`).
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
    let delegated = try XCTUnwrap(environment["OPENCODE_AGENTS_DELEGATED"])
    XCTAssertEqual(order.first, delegated, "the newest start is the real delegation")
    let background = try XCTUnwrap(environment["OPENCODE_AGENTS_BACKGROUND"])
    let script = try XCTUnwrap(environment["OPENCODE_AGENTS_SCRIPT"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_AGENTS_PARENT"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    let agents = app.buttons["conversation-agents"]
    XCTAssertTrue(agents.waitForExistence(timeout: 30))
    // The pill appears with the first snapshot; the family and shells may complete it a moment later.
    let counted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "3 agentes e 1 script em execução"), object: agents)
    XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 20), .completed, agents.label)
    screenshot("conversation")

    // A pushed screen with a back button, not a sheet with a grabber and Concluir.
    agents.tap()
    let bar = app.navigationBars["Agentes e tarefas"]
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    XCTAssertTrue(bar.buttons.element(boundBy: 0).exists)
    XCTAssertFalse(app.buttons["Concluir"].exists)
    // Native segmented tabs, always opening on Agentes.
    let agentsTab = app.buttons["Agentes (\(order.count))"]
    let scriptsTab = app.buttons["Scripts (1)"]
    XCTAssertTrue(agentsTab.waitForExistence(timeout: 20))
    XCTAssertTrue(agentsTab.isSelected)
    XCTAssertFalse(row(app, script).exists, "a script is never listed as an agent")
    XCTAssertFalse(app.staticTexts["Shell em background"].exists)
    XCTAssertFalse(app.staticTexts["Sem recursos"].exists)
    let rows = order.map { row(app, $0) }
    XCTAssertTrue(rows.allSatisfy { $0.waitForExistence(timeout: 20) })
    XCTAssertEqual(rows.map(\.frame.minY), rows.map(\.frame.minY).sorted(), "running first, then by latest activity")
    XCTAssertEqual(rows.map { $0.value as? String },
      ["Em execução", "Em execução", "Em execução", "Interrompido", "Erro", "Concluído"])
    XCTAssertEqual(rows[1].identifier, "agent-work-" + background, "a background subagent is an agent")
    XCTAssertEqual(rows[2].identifier, "agent-work-" + running, "an old child resumed now is above the finished ones")
    // One row per child: the delegation's running call merges into its session instead of a second row.
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-work-'")).count, order.count)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-work-toolu' OR identifier BEGINSWITH 'agent-work-call'")).firstMatch.exists)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Parar '")).count, 3)
    XCTAssertTrue(app.buttons["Parar Executar verificação longa"].exists)
    screenshot("list")

    // Scripts: the background shell with its command, state and stop action; none of the agents.
    scriptsTab.tap()
    XCTAssertTrue(scriptsTab.isSelected)
    let scriptRow = row(app, script)
    XCTAssertTrue(scriptRow.waitForExistence(timeout: 10))
    XCTAssertEqual(scriptRow.value as? String, "Em execução")
    XCTAssertTrue(scriptRow.staticTexts["sleep 301"].exists)
    XCTAssertFalse(scriptRow.staticTexts["Iniciando"].exists)
    XCTAssertTrue(app.buttons["Parar sleep 301"].exists)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-work-'")).count, 1)
    XCTAssertFalse(row(app, delegated).exists)
    screenshot("scripts")
    agentsTab.tap()
    XCTAssertTrue(rows[0].waitForExistence(timeout: 10))

    // Stopping the newest running child moves it down to the finished group, as the most recent one to have run.
    app.buttons["Parar Delegar verificação real"].tap()
    let confirm = app.buttons.matching(NSPredicate(format: "label == 'Parar'")).firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Interrompido'"), object: rows[0])
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 30), .completed, rows[0].value as? String ?? "")
    let after = [1, 2, 0, 3, 4, 5].map { rows[$0] }
    // The reorder waits for the list to stop scrolling and animates briefly.
    let deadline = Date().addingTimeInterval(10)
    while after.map(\.frame.minY) != after.map(\.frame.minY).sorted() && Date() < deadline { usleep(200_000) }
    XCTAssertEqual(after.map(\.frame.minY), after.map(\.frame.minY).sorted())
    XCTAssertEqual(after.map { $0.value as? String },
      ["Em execução", "Em execução", "Interrompido", "Interrompido", "Erro", "Concluído"])
    screenshot("list-after-stop")

    // The delegated row opens its child, not the root.
    row(app, delegated).tap()
    let title = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 20))
    XCTAssertEqual(title.label, "Delegar verificação real")
    screenshot("delegated-child")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(bar.waitForExistence(timeout: 10))

    // A finished child opens; Back returns to the list, then to the conversation.
    rows[5].tap()
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    XCTAssertEqual(title.label, "Mapear dependências")
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 20))
    screenshot("child")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    XCTAssertTrue(row(app, running).waitForExistence(timeout: 10))
    screenshot("list-after-child")
    // Leave Scripts selected: the next visit opens on Agentes again.
    scriptsTab.tap()
    XCTAssertTrue(scriptsTab.isSelected)
    bar.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(agents.waitForExistence(timeout: 10))
    XCTAssertFalse(bar.exists)
    XCTAssertEqual(title.label, "Agentes e tarefas")

    // A child opened from the list: "Voltar à sessão principal" skips the list and lands on the parent conversation.
    agents.tap()
    XCTAssertTrue(agentsTab.waitForExistence(timeout: 10))
    XCTAssertTrue(agentsTab.isSelected)
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
