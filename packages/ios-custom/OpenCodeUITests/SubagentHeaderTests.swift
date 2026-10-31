import XCTest

/// A subagent's conversation and "Agentes e tarefas" with each subagent's Progresso (rev. 2026-10-30), against an
/// isolated sandbox (`script/test-subagent-header.py`): `OPENCODE_SUB_PARENT` (idle) has `OPENCODE_SUB_CHILD`,
/// running with a Progresso of 2/4 it wrote before the app opened, and `OPENCODE_SUB_SIBLING`, finished without
/// subagents. The child has its own subagents: `OPENCODE_SUB_GRANDCHILD` running and `OPENCODE_SUB_GRANDCHILD_DONE`
/// finished. One run covers both themes: the captures in the light one, then the whole flow in the dark one.
@MainActor final class SubagentHeaderTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme = "openchamber-dark"
  private func value(_ key: String) throws -> String { try XCTUnwrap(environment[key], key) }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "subagent-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func launch() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try value("OPENCODE_SUB_PARENT")]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try value("OPENCODE_TEST_PASSWORD")
    app.launch()
    try app.requireSandbox()
    let title = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "label == %@", try value("OPENCODE_SUB_TITLE")), on: title)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 30) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout),
      .completed, element.debugDescription)
  }
  /// The parent's "Agentes e tarefas", with the child's `☑ 2/4` from the family snapshot: the app opened after the
  /// child wrote its list, so no live event carried it.
  private func openParentAgents(_ app: XCUIApplication) throws -> XCUIElement {
    let agents = app.buttons["conversation-agents"]
    XCTAssertTrue(agents.waitForExistence(timeout: 30))
    agents.tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    let progress = app.buttons["agent-progress-" + (try value("OPENCODE_SUB_CHILD"))]
    XCTAssertTrue(progress.waitForExistence(timeout: 60))
    XCTAssertEqual(progress.label, "Progresso 2 de 4")
    return progress
  }

  func testSubagentHeaderPathCapsuleAndProgresso() throws {
    let child = try value("OPENCODE_SUB_CHILD")
    let grandchild = try value("OPENCODE_SUB_GRANDCHILD")
    let finished = try value("OPENCODE_SUB_GRANDCHILD_DONE")
    let sibling = try value("OPENCODE_SUB_SIBLING")
    let app = try launch()
    defer { app.terminate() }
    // The parent's own list: the child with the Mac's line and its Progresso; the line says what it does now.
    let progress = try openParentAgents(app)
    XCTAssertTrue(app.staticTexts["agent-activity-" + child].label.hasPrefix("agora: "))
    XCTAssertTrue(app.buttons["Parar Etapa 1: confronto F12"].exists)
    XCTAssertTrue(app.buttons["agent-work-" + sibling].exists)
    XCTAssertFalse(app.buttons["agent-work-" + grandchild].exists, "a grandchild is listed by its own parent only")
    screenshot("agents-progress")

    // ☑ 2/4 opens the child's whole list; "Abrir subagente" opens it.
    progress.tap()
    XCTAssertTrue(app.buttons["agent-progress-open"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["conversation-progress-item-3"].exists)
    screenshot("progress-sheet")
    app.buttons["agent-progress-open"].tap()
    let title = app.staticTexts["conversation-header-title"]
    wait(NSPredicate(format: "label == 'Etapa 1: confronto F12'"), on: title)

    // The child: SUBAGENTE · <agente>, "de <pai>", no link back at the bottom; its capsule counts its own subagents.
    let kicker = app.staticTexts["subagent-kicker"]
    XCTAssertTrue(kicker.waitForExistence(timeout: 10))
    XCTAssertTrue(kicker.label.hasPrefix("SUBAGENTE · "), kicker.label)
    XCTAssertFalse(kicker.label.contains("NÍVEL"))
    XCTAssertFalse(app.buttons["Voltar à sessão principal"].exists)
    let capsule = app.buttons["conversation-agents"]
    XCTAssertTrue(capsule.waitForExistence(timeout: 30))
    wait(NSPredicate(format: "label == '1 agente em execução'"), on: capsule)
    screenshot("child")

    // Its capsule opens its own "Agentes e tarefas": its subagents, not its siblings.
    capsule.tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["agent-work-" + grandchild].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["agent-work-" + finished].exists)
    XCTAssertFalse(app.buttons["agent-work-" + sibling].exists)
    XCTAssertFalse(app.buttons["agent-work-" + child].exists)
    screenshot("child-agents")

    // Level 2: NÍVEL 2, no capsule (no subagents of its own), the path with three levels.
    app.buttons["agent-work-" + grandchild].tap()
    wait(NSPredicate(format: "label == 'Conferir regras F12b'"), on: title)
    XCTAssertTrue(kicker.waitForExistence(timeout: 10))
    wait(NSPredicate(format: "label BEGINSWITH 'SUBAGENTE · NÍVEL 2 · '"), on: kicker)
    XCTAssertFalse(app.buttons["conversation-agents"].exists, "no subagents: the capsule is gone")
    screenshot("level-2")
    app.buttons["subagent-badge"].tap()
    let levels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subagent-path-'"))
    XCTAssertTrue(levels.element(boundBy: 2).waitForExistence(timeout: 10))
    XCTAssertEqual(levels.count, 3)
    XCTAssertTrue(levels.element(boundBy: 0).label.contains(try value("OPENCODE_SUB_TITLE")))
    XCTAssertTrue(levels.element(boundBy: 1).label.contains("Etapa 1: confronto F12"))
    XCTAssertTrue(levels.element(boundBy: 2).label.contains("você está aqui"))
    screenshot("path")
    app.buttons["Fechar"].tap()
    XCTAssertTrue(levels.element(boundBy: 0).waitForNonExistence(timeout: 5))

    // A long press on Back lists the levels; the child's level goes back down the stack to it.
    let back = app.buttons["conversation-back"]
    back.press(forDuration: 1.2)
    let parentLevel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", try value("OPENCODE_SUB_TITLE"))).firstMatch
    XCTAssertTrue(parentLevel.waitForExistence(timeout: 5))
    let childLevel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Etapa 1: confronto F12'")).firstMatch
    XCTAssertTrue(childLevel.exists)
    screenshot("levels-menu")
    childLevel.tap()
    wait(NSPredicate(format: "label == 'Etapa 1: confronto F12'"), on: title)

    // Back still returns to where Alexandre came from: the parent's list, not its conversation.
    back.tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["agent-progress-" + child].waitForExistence(timeout: 10))

    // Stopping one of the child's own subagents from its list; its capsule then keeps the grey icon only.
    app.buttons["agent-work-" + child].tap()
    wait(NSPredicate(format: "label == 'Etapa 1: confronto F12'"), on: title)
    capsule.tap()
    XCTAssertTrue(app.buttons["agent-work-" + grandchild].waitForExistence(timeout: 20))
    app.buttons["Parar Conferir regras F12b"].tap()
    let confirm = app.buttons.matching(NSPredicate(format: "label == 'Parar'")).firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    wait(NSPredicate(format: "value == 'Interrompido'"), on: app.buttons["agent-work-" + grandchild])
    XCTAssertFalse(app.buttons["Parar Conferir regras F12b"].exists)
    app.navigationBars["Agentes e tarefas"].buttons.element(boundBy: 0).tap()
    wait(NSPredicate(format: "label == 'Agentes e tarefas'"), on: capsule)
    screenshot("child-agents-finished")

    // The sibling without subagents: no capsule.
    back.tap()
    XCTAssertTrue(app.buttons["agent-work-" + sibling].waitForExistence(timeout: 10))
    app.buttons["agent-work-" + sibling].tap()
    wait(NSPredicate(format: "label == 'Etapa 2: inventário F12'"), on: title)
    XCTAssertTrue(app.staticTexts["subagent-kicker"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["conversation-agents"].exists)
    screenshot("sibling")
  }

  /// The same screens in the light theme, without acting on the sessions.
  func testSubagentCaptures() throws {
    theme = "openchamber-light"
    let app = try launch()
    defer { app.terminate() }
    let progress = try openParentAgents(app)
    screenshot("agents-progress")
    progress.tap()
    XCTAssertTrue(app.buttons["agent-progress-open"].waitForExistence(timeout: 10))
    screenshot("progress-sheet")
    app.buttons["agent-progress-open"].tap()
    let title = app.staticTexts["conversation-header-title"]
    wait(NSPredicate(format: "label == 'Etapa 1: confronto F12'"), on: title)
    XCTAssertTrue(app.staticTexts["subagent-kicker"].waitForExistence(timeout: 10))
    wait(NSPredicate(format: "label == '1 agente em execução'"), on: app.buttons["conversation-agents"])
    screenshot("child")
    app.buttons["subagent-badge"].tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subagent-path-'")).element(boundBy: 1)
      .waitForExistence(timeout: 10))
    screenshot("path")
  }
}
