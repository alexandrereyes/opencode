import XCTest

/// A finished subagent whose shells still run, against an owned sandbox (`script/test-background-agents.py`): its
/// parent's header and its row in Agentes say "em segundo plano" without claiming a model executes, its shells stay
/// in its own Scripts (the root's stays empty), and once they end it returns to the finished ones without reopening.
/// `OPENCODE_BG_C0` owns one shell; `OPENCODE_BG_C1` has a child in another worktree that owns one, ending later.
@MainActor final class BackgroundAgentsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  func testSubagentShellsKeepItWorkingInTheBackground() throws {
    let root = try XCTUnwrap(environment["OPENCODE_BG_ROOT"])
    let c0 = try XCTUnwrap(environment["OPENCODE_BG_C0"])
    let c1 = try XCTUnwrap(environment["OPENCODE_BG_C1"])
    let c0Ends = try XCTUnwrap(environment["OPENCODE_BG_C0_ENDS"].flatMap(Double.init)) / 1000
    let c1Ends = try XCTUnwrap(environment["OPENCODE_BG_C1_ENDS"].flatMap(Double.init)) / 1000
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeOpenSession", root,
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()

    // The parent: no model executes, its family works in the background.
    let capsule = app.buttons["conversation-agents"]
    XCTAssertTrue(capsule.waitForExistence(timeout: 30))
    wait(NSPredicate(format: "label CONTAINS 'trabalho em segundo plano'"), on: capsule, timeout: 30)
    XCTAssertFalse(capsule.label.contains("em execução"), capsule.label)
    let subtitle = app.staticTexts["conversation-header-subtitle"]
    wait(NSPredicate(format: "label CONTAINS 'em segundo plano'"), on: subtitle)
    screenshot(app, "1-cabecalho-pai")

    // Agentes: both are listed with the live ones, above the finished ones, without a stop button.
    capsule.tap()
    let first = app.buttons["agent-work-" + c0]
    let second = app.buttons["agent-work-" + c1]
    XCTAssertTrue(first.waitForExistence(timeout: 20))
    wait(NSPredicate(format: "value == 'Em segundo plano'"), on: first)
    wait(NSPredicate(format: "value == 'Em segundo plano'"), on: second)
    XCTAssertTrue(app.staticTexts["agent-activity-" + c0].label.hasPrefix("em segundo plano · 1 script"),
      app.staticTexts["agent-activity-" + c0].label)
    XCTAssertTrue(app.staticTexts["agent-activity-" + c1].label.hasPrefix("em segundo plano · 1 script"))
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Parar '")).count, 0)
    let finished = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-work-' AND value == 'Concluído'"))
    XCTAssertGreaterThan(finished.count, 0)
    XCTAssertLessThan(max(first.frame.minY, second.frame.minY), finished.element(boundBy: 0).frame.minY)
    XCTAssertTrue(app.buttons["agents-finished-toggle"].exists, "the other finished subagents stay collapsed")
    screenshot(app, "2-agentes-em-segundo-plano")
    app.buttons["Scripts (0)"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["scripts-empty"].waitForExistence(timeout: 5))
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agentes ('")).firstMatch.tap()

    // Its shell is its own: opening it shows the script running there.
    first.tap()
    let own = app.buttons["conversation-agents"]
    XCTAssertTrue(own.waitForExistence(timeout: 20))
    wait(NSPredicate(format: "label CONTAINS '1 script em execução'"), on: own)
    own.tap()
    XCTAssertTrue(app.buttons["Scripts (1)"].waitForExistence(timeout: 20))
    app.buttons["Scripts (1)"].tap()
    screenshot(app, "3-scripts-do-dono")
    app.navigationBars["Agentes e tarefas"].buttons.element(boundBy: 0).tap()
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(first.waitForExistence(timeout: 20))

    // Its shell ends: it returns to the finished ones on its own; the grandchild's shell keeps c1 working.
    wait(NSPredicate(format: "value == 'Concluído'"), on: first, timeout: max(30, c0Ends - Date().timeIntervalSince1970 + 45))
    XCTAssertEqual(second.value as? String, "Em segundo plano")
    screenshot(app, "4-um-terminou")

    // The last one ends: nothing works in the background any more.
    let background = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'agent-work-' AND value == 'Em segundo plano'"))
    let deadline = max(30, c1Ends - Date().timeIntervalSince1970 + 45)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: background)], timeout: deadline),
      .completed)
    app.navigationBars["Agentes e tarefas"].buttons.element(boundBy: 0).tap()
    wait(NSPredicate(format: "NOT (label CONTAINS 'segundo plano')"), on: capsule, timeout: 20)
    XCTAssertFalse(subtitle.exists && subtitle.label.contains("em segundo plano"))
    screenshot(app, "5-tudo-terminou")
  }

  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 20) {
    let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
    XCTAssertEqual(result, .completed, "\(predicate) · \(element.debugDescription.prefix(300))")
  }

  private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
