import XCTest

/// The LLM proxy details on the iPhone ("Agora primeiro", rev. 2026-11-01) with the stubbed proxy
/// (`OPENCODE_PROXY_STUB=marks|many`, `SubscriptionMarksFixture`): no proxy, model or reset is touched. Codex and
/// Claude switch in one tap; "Agora" carries the Sessões strip's marks, the next release and the next weekly renewal;
/// every plan lists each account with its state in words, its windows and its own credits and resets; Free accounts
/// stay "Sem medição", never 0%; "Destacar no resumo" keeps the details open. Run in both themes with
/// `script/test-subscriptions.py OpenCodeUITests/SubscriptionDetailsTests` and an explicit sandbox.
@MainActor final class SubscriptionDetailsTests: XCTestCase {
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ stub: String, largeText: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_PROXY_STUB"] = stub
    app.launch()
    try app.requireSandbox()
    XCTAssertTrue(app.buttons["proxy-strip-codex"].waitForExistence(timeout: 25))
    return app
  }
  private func open(_ app: XCUIApplication, _ provider: String) {
    app.buttons["proxy-strip-" + provider].tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.otherElements["proxy-now"].waitForExistence(timeout: 20))
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "detalhes-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ element: XCUIElement, _ format: String, _ value: String) {
    let predicate = NSPredicate(format: format, value)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed,
      "\(element.identifier): \(element.exists ? element.label + " · " + String(describing: element.value) : "ausente")")
  }
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }
  private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
    for _ in 0..<20 {
      if element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 45 { return }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(element.exists && element.isHittable, element.identifier)
  }

  func testCodexAndClaudeShowEveryAccountWithItsStateWindowsAndActions() throws {
    let app = try launch("marks")
    defer { app.terminate() }
    open(app, "codex")
    XCTAssertTrue(app.buttons["proxy-provider-codex"].isSelected)
    // The strip's marks, the same order and states; a count of accounts, never a combined balance.
    wait(element(app, "proxy-now-marks"), "value == %@", "Pro Max:R|Pro 5x:BE|Free:??")
    wait(app.staticTexts["proxy-ready"], "label == %@", "1 de 5 prontas")
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Pro 20x' OR label CONTAINS 'combinada' OR label CONTAINS 'Outros planos'")).firstMatch.exists)
    // The release names the account and its window; the weekly renewal is apart, with its own account.
    wait(element(app, "proxy-release"), "label BEGINSWITH %@", "Próxima liberação: Kauri · ")
    wait(element(app, "proxy-release"), "label ENDSWITH %@", ", janela de 5 horas")
    wait(element(app, "proxy-renewal"), "label BEGINSWITH %@", "Próxima renovação semanal: Jade · ")
    XCTAssertTrue(app.staticTexts["proxy-updated"].label.hasPrefix("Medição mais antiga há "), app.staticTexts["proxy-updated"].label)
    // Plans in the strip's order, each account with its state in words.
    let plans = ["promax", "prolite", "free"].map { element(app, "proxy-plan-" + $0) }
    XCTAssertTrue(plans.allSatisfy { $0.waitForExistence(timeout: 10) })
    wait(element(app, "proxy-state-iris"), "label == %@", "Pronta")
    wait(element(app, "proxy-window-5h-iris"), "label BEGINSWITH %@", "5 horas: 64% restantes, renova ")
    wait(element(app, "proxy-window-week-iris"), "label BEGINSWITH %@", "Semana: 81% restantes, renova ")
    XCTAssertTrue(element(app, "proxy-account-iris").staticTexts["Créditos pagos 21.877 · 0 redefinições"].exists)
    shot("codex")
    wait(element(app, "proxy-state-kauri"), "label BEGINSWITH %@", "Parada até ")
    wait(element(app, "proxy-window-5h-kauri"), "label BEGINSWITH %@", "5 horas: 0% restantes, libera ")
    wait(element(app, "proxy-state-jade"), "label == %@", "Semana esgotada")
    // An exhausted week hides the 5-hour window, as before.
    XCTAssertFalse(element(app, "proxy-window-5h-jade").exists)
    reveal(element(app, "proxy-account-mira"), app)
    XCTAssertTrue(plans[0].frame.minY < plans[1].frame.minY && plans[1].frame.minY < plans[2].frame.minY)
    // Free accounts: no window and no percent at all, never 0%.
    for free in ["lume", "mira"] {
      let account = element(app, "proxy-account-" + free)
      XCTAssertTrue(account.staticTexts["Sem medição"].exists)
      XCTAssertFalse(element(app, "proxy-window-week-" + free).exists || account.staticTexts["0%"].exists)
    }
    shot("codex-planos")

    // "Destacar no resumo" rings the mark and keeps the details open; a second tap removes it.
    let pin = app.buttons["proxy-select-kauri"]
    reveal(pin, app)
    pin.tap()
    XCTAssertTrue(pin.isSelected)
    wait(pin, "label == %@", "Kauri destacada no resumo")
    XCTAssertTrue(app.buttons["proxy-close"].exists)
    shot("codex-destacada")
    pin.tap()
    wait(pin, "label == %@", "Destacar Kauri no resumo")

    // "Usar redefinição" still asks first; the stub is never asked to consume one here.
    let reset = app.buttons["proxy-reset-kauri"]
    reveal(reset, app)
    reset.tap()
    XCTAssertTrue(app.alerts["Consumir uma redefinição?"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancelar"].tap()
    let automation = app.switches["proxy-automation"]
    reveal(automation, app)
    XCTAssertTrue(app.staticTexts["proxy-resets-summary"].label.hasPrefix("1 disponível em 3 contas"), app.staticTexts["proxy-resets-summary"].label)
    shot("codex-redefinicoes")

    // Claude in one tap: its own marks, the proxy's wait as the release cause.
    app.buttons["proxy-provider-anthropic"].tap()
    XCTAssertTrue(app.buttons["proxy-provider-anthropic"].isSelected)
    wait(element(app, "proxy-now-marks"), "value == %@", "Max 5x:RRRRB|Max 20x:EE")
    wait(app.staticTexts["proxy-ready"], "label == %@", "4 de 7 prontas")
    wait(element(app, "proxy-release"), "label BEGINSWITH %@", "Próxima liberação: Eco · ")
    wait(element(app, "proxy-release"), "label ENDSWITH %@", ", espera do proxy")
    app.swipeDown(velocity: .slow)
    shot("claude")
    reveal(element(app, "proxy-account-farol"), app)
    wait(element(app, "proxy-state-farol"), "label == %@", "Semana esgotada")
    shot("claude-planos")

    // Refresh keeps the provider and the content.
    app.swipeDown(velocity: .fast)
    app.swipeDown(velocity: .fast)
    let refresh = app.buttons["proxy-refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 5))
    refresh.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: refresh)], timeout: 20), .completed)
    XCTAssertTrue(app.buttons["proxy-provider-anthropic"].isSelected)
    wait(app.staticTexts["proxy-ready"], "label == %@", "4 de 7 prontas")
    app.buttons["proxy-provider-codex"].tap()
    wait(app.staticTexts["proxy-ready"], "label == %@", "1 de 5 prontas")
    app.buttons["proxy-close"].tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForNonExistence(timeout: 5))
  }

  func testLargeTextStacksTheWindowsInsideTheScreen() throws {
    let app = try launch("marks", largeText: true)
    defer { app.terminate() }
    open(app, "codex")
    wait(app.staticTexts["proxy-ready"], "label == %@", "1 de 5 prontas")
    let window = element(app, "proxy-window-week-iris")
    reveal(window, app)
    let width = app.windows.firstMatch.frame.width
    XCTAssertGreaterThanOrEqual(window.frame.minX, 0)
    XCTAssertLessThanOrEqual(window.frame.maxX, width, "\(window.frame)")
    shot("texto-grande")
  }

  func testManyAccountsAndPlansStayListed() throws {
    let app = try launch("many")
    defer { app.terminate() }
    open(app, "anthropic")
    // Past 12 accounts a plan shows counts by state in "Agora"; every account is still listed below.
    wait(element(app, "proxy-now-marks"), "value == %@", "Max 5x:RRRRBRRBRRBRRBRR|Max 20x:EE|Plano desconhecido:R|Team:R")
    wait(app.staticTexts["proxy-ready"], "label == %@", "14 de 20 prontas")
    shot("muitas")
    reveal(element(app, "proxy-account-time"), app)
    XCTAssertTrue(element(app, "proxy-plan-team").exists)
    app.buttons["proxy-provider-codex"].tap()
    wait(element(app, "proxy-now-marks"), "value == %@", "Pro Max:R!|Pro 5x:BE?|Plus:R|Free:????????")
    wait(element(app, "proxy-state-sem-login"), "label == %@", "Precisa de login")
    shot("muitas-codex")
  }
}
