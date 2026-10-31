import XCTest

/// A subagent's header has no … button: its right side is the same agents capsule as a top-level session's, with
/// this subagent's own subagents and the resources it uses (`resource.owner`), and the … actions that make sense in
/// a subagent are a long press on its title. Against an isolated sandbox (`script/test-subagent-capsule.py`):
/// `OPENCODE_CAP_PARENT` has four subagents, `OPENCODE_CAP_BOTH` (a running subagent of its own and a resource in
/// use), `OPENCODE_CAP_RESOURCE` (only a resource), `OPENCODE_CAP_AGENTS` (only a finished subagent) and
/// `OPENCODE_CAP_NONE`.
@MainActor final class SubagentCapsuleTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme = "openchamber-dark"
  private func value(_ key: String) throws -> String { try XCTUnwrap(environment[key], key) }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "capsule-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 30) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout),
      .completed, element.debugDescription)
  }
  /// Opens one session directly, like a notification would, after confirming the app talks to the sandbox.
  private func launch(_ key: String, title: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try value(key)]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try value("OPENCODE_TEST_PASSWORD")
    app.launch()
    try app.requireSandbox()
    let header = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(header.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "label == %@", title), on: header)
    return app
  }
  /// The subagent's header: the badge, no … button, and the capsule with `label`, or none.
  private func header(_ app: XCUIApplication, capsule label: String?) {
    XCTAssertTrue(app.staticTexts["subagent-kicker"].waitForExistence(timeout: 10))
    let capsule = app.buttons["conversation-agents"]
    if let label {
      XCTAssertTrue(capsule.waitForExistence(timeout: 30))
      wait(NSPredicate(format: "label == %@", label), on: capsule)
    } else {
      // The family and resources load after the transcript: give them the time the capsule would need.
      XCTAssertFalse(capsule.waitForExistence(timeout: 8), "nothing to count: no capsule")
    }
    XCTAssertFalse(app.buttons["Mais opções"].exists, "a subagent has no … button")
  }
  private func longPress(_ app: XCUIApplication, _ action: String) {
    app.buttons["subagent-badge"].press(forDuration: 1.0)
    let item = app.buttons[action]
    XCTAssertTrue(item.waitForExistence(timeout: 5), action)
    item.tap()
  }

  func testHeaderCapsuleAndLongPressActions() throws {
    let child = try value("OPENCODE_CAP_GRANDCHILD")
    let resource = try value("OPENCODE_CAP_BOTH_RESOURCE")

    // Subagents and resources: its running subagent and the resource it uses; the capsule opens its own list.
    var app = try launch("OPENCODE_CAP_BOTH", title: "Etapa 1: confronto F12")
    header(app, capsule: "1 agente em execução, 1 recurso ativo")
    screenshot("both")
    app.buttons["conversation-agents"].tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Agentes (1)"].isSelected, "resources are listed in Agentes")
    XCTAssertTrue(app.buttons["agent-work-" + child].waitForExistence(timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["resource-row-" + resource].waitForExistence(timeout: 20))
    screenshot("both-agents")
    app.navigationBars["Agentes e tarefas"].buttons.element(boundBy: 0).tap()

    // The … actions moved to a long press on the title: search, rename and details.
    app.buttons["subagent-badge"].press(forDuration: 1.0)
    XCTAssertTrue(app.buttons["Buscar na conversa"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Renomear"].exists && app.buttons["Detalhes da sessão"].exists)
    XCTAssertFalse(app.buttons["Excluir sessão"].exists || app.buttons["Nova sessão"].exists)
    screenshot("long-press")
    app.buttons["Buscar na conversa"].tap()
    XCTAssertTrue(app.textFields["conversation-search"].waitForExistence(timeout: 5))
    app.buttons["conversation-search-close"].tap()
    XCTAssertTrue(app.buttons["subagent-badge"].waitForExistence(timeout: 5))
    longPress(app, "Renomear")
    XCTAssertTrue(app.alerts["Renomear sessão"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    // The whole title comes selected: typing replaces it.
    app.typeText("Etapa 1 renomeada")
    app.alerts.buttons["Salvar"].tap()
    wait(NSPredicate(format: "label == 'Etapa 1 renomeada'"), on: app.staticTexts["conversation-header-title"])
    longPress(app, "Detalhes da sessão")
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    app.buttons["Fechar"].tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForNonExistence(timeout: 5))
    // The badge's tap still opens the path.
    app.buttons["subagent-badge"].tap()
    XCTAssertTrue(app.buttons["subagent-path-" + (try value("OPENCODE_CAP_PARENT"))].waitForExistence(timeout: 10))
    app.buttons["Fechar"].tap()
    app.terminate()

    // Only a resource: the neutral agents icon without a number, then the resource it uses.
    app = try launch("OPENCODE_CAP_RESOURCE", title: "Etapa 2: inventário F12")
    header(app, capsule: "Agentes e tarefas, 1 recurso ativo")
    screenshot("resource")
    app.buttons["conversation-agents"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["resource-row-" + (try value("OPENCODE_CAP_RESOURCE_RESOURCE"))]
      .waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["Nenhum subagente nesta sessão."].exists)
    app.terminate()

    // Only a finished subagent: the neutral icon and no resource half.
    app = try launch("OPENCODE_CAP_AGENTS", title: "Etapa 3: regras F12")
    header(app, capsule: "Agentes e tarefas")
    screenshot("agents")
    app.buttons["conversation-agents"].tap()
    XCTAssertTrue(app.buttons["agent-work-" + (try value("OPENCODE_CAP_AGENTS_CHILD"))].waitForExistence(timeout: 20))
    app.terminate()

    // Nothing to count: no capsule and no … button; the long press still searches.
    app = try launch("OPENCODE_CAP_NONE", title: "Etapa 4: notas F12")
    header(app, capsule: nil)
    screenshot("none")
    longPress(app, "Buscar na conversa")
    XCTAssertTrue(app.textFields["conversation-search"].waitForExistence(timeout: 5))
    app.terminate()

    // The top-level session is unchanged: its … button and the capsule with every resource of the family.
    app = try launch("OPENCODE_CAP_PARENT", title: try value("OPENCODE_CAP_TITLE"))
    XCTAssertTrue(app.buttons["Mais opções"].waitForExistence(timeout: 10))
    wait(NSPredicate(format: "label == 'Agentes e tarefas, 2 recursos ativos'"), on: app.buttons["conversation-agents"])
    XCTAssertFalse(app.staticTexts["subagent-kicker"].exists)
    screenshot("parent")
    app.terminate()
  }

  /// The four headers in the light theme, without acting on the sessions. It runs first (alphabetical order), before
  /// the other test renames a subagent.
  func testCapsuleCapturesInLightTheme() throws {
    theme = "openchamber-light"
    for (key, title, name, label) in [
      ("OPENCODE_CAP_BOTH", "Etapa 1: confronto F12", "both", "1 agente em execução, 1 recurso ativo"),
      ("OPENCODE_CAP_RESOURCE", "Etapa 2: inventário F12", "resource", "Agentes e tarefas, 1 recurso ativo"),
      ("OPENCODE_CAP_AGENTS", "Etapa 3: regras F12", "agents", "Agentes e tarefas"),
    ] {
      let app = try launch(key, title: title)
      header(app, capsule: label)
      screenshot(name)
      app.terminate()
    }
    let app = try launch("OPENCODE_CAP_NONE", title: "Etapa 4: notas F12")
    header(app, capsule: nil)
    screenshot("none")
    app.buttons["subagent-badge"].press(forDuration: 1.0)
    XCTAssertTrue(app.buttons["Buscar na conversa"].waitForExistence(timeout: 5))
    screenshot("long-press")
    app.terminate()
  }
}
