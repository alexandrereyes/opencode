import XCTest

/// The Sessões quota strip (rev. 2026-11-01): every account of every plan as a mark, with the stubbed proxy
/// (`SubscriptionMarksFixture`, no proxy or model call). It stays within the old rings' row (38 pt) above the
/// project chips and inside the screen margin, falls back to counts with many accounts, and opens the details.
/// Run in both themes and on a narrow iPhone (`script/test-subscriptions.py` with `OPENCODE_TEST_THEME`).
@MainActor final class SessionQuotaMarksTests: XCTestCase {
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
    XCTAssertTrue(app.buttons["proxy-strip-anthropic"].waitForExistence(timeout: 25))
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "cotas-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ element: XCUIElement, value: String) {
    let loaded = NSPredicate(format: "value == %@", value)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: loaded, evaluatedWith: element)], timeout: 20), .completed,
      "\(element.identifier): \(element.value ?? "-")")
  }
  /// Above the chips, inside the margins and, unless stacked for large text, no taller than the old row.
  private func checkGeometry(_ app: XCUIApplication, stacked: Bool = false) {
    let claude = app.buttons["proxy-strip-anthropic"].frame
    let codex = app.buttons["proxy-strip-codex"].frame
    let chips = app.buttons["filter-all"].frame
    let width = app.windows.firstMatch.frame.width
    XCTContext.runActivity(named: "faixa: Claude \(claude) · Codex \(codex) · chips \(chips) · tela \(width)") { _ in }
    for frame in [claude, codex] {
      XCTAssertGreaterThanOrEqual(frame.minX, 15.5, "a faixa sai pela margem esquerda: \(frame)")
      XCTAssertLessThanOrEqual(frame.maxX, width - 15.5, "a faixa sai pela margem direita: \(frame)")
      XCTAssertLessThan(frame.maxY, chips.minY, "a faixa cobre os chips: \(frame) · \(chips)")
    }
    // Side by side or one line each, the strip stays within the old rings' row.
    let strip = claude.union(codex)
    // 33 pt: the height the strip had before the rings (two lines of marks and summary, or one line each).
    if !stacked { XCTAssertLessThanOrEqual(strip.height, 33.5, "a faixa ficou mais alta que antes dos anéis: \(strip)") }
  }

  func testEveryPlanAndAccountShowsAsAMarkAndOpensTheDetails() throws {
    let app = try launch("marks")
    defer { app.terminate() }
    let claude = app.buttons["proxy-strip-anthropic"]
    let codex = app.buttons["proxy-strip-codex"]
    // Ready rings first with each account's own balance, larger first within the plan; then the other states, each
    // with its own wait when the data gives one (Eco 1 h 50 → 2h; the 20x weeks renew in 3 days).
    wait(claude, value: "5x:100,72,64,41,B2h|20x:E3d,E3d")
    wait(codex, value: "Pro Max:64|5x:B3h,E2d|Free:?,?")
    XCTAssertTrue(claude.label.hasPrefix("Claude, 4 de 7 assinaturas prontas agora. Max 5x: 4 prontas, 1 parada. Max 20x: 2 com a semana esgotada."), claude.label)
    XCTAssertTrue(claude.label.contains("Mais 1 às "), claude.label)
    XCTAssertTrue(codex.label.contains("Free: 2 sem medição"), codex.label)
    // The number's window and what is unknown are spoken, never read as a capacity.
    XCTAssertTrue(claude.label.contains(". Saldos: Brisa 100% em 5 horas (semana não informada), Atlas 72% na semana, Cedro 64% na semana, Duna 41% na semana. Prazos: Eco volta "), claude.label)
    XCTAssertTrue(codex.label.contains(". Saldos: Iris 64% em 5 horas. Prazos: Kauri volta "), codex.label)
    checkGeometry(app)
    shot("varias")
    claude.tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["proxy-provider-anthropic"].isSelected)
    shot("detalhes")
    app.buttons["proxy-close"].tap()
    XCTAssertTrue(codex.waitForExistence(timeout: 10))
    codex.tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["proxy-provider-codex"].isSelected)
    app.buttons["proxy-close"].tap()
  }

  /// The approved "Relógio + prazo" mockup: each stopped account's own wait next to its clock, an exhausted week's
  /// renewal next to the renewal arrow, nothing for an unexplained refusal, login or Free.
  func testEachStoppedAccountShowsItsOwnWaitAndTheHighlightStaysUnderItsMark() throws {
    let app = try launch("waits")
    defer { app.terminate() }
    let claude = app.buttons["proxy-strip-anthropic"]
    let codex = app.buttons["proxy-strip-codex"]
    // Stopped by release, the unexplained one last and without a time; then the week, back in 1 day and 22 hours.
    wait(claude, value: "5x:100,9,B35m,B2h,B|20x:E2d")
    // Kauri's 5-hour window is back in 50 minutes, but the proxy waits 2 hours: the later one.
    wait(codex, value: "Pro Max:78|Plus:B2h|Pro Max:!|Free:?,?")
    XCTAssertTrue(claude.label.contains(". Prazos: Eco volta "), claude.label)
    XCTAssertTrue(claude.label.contains(", em 35 min (previsto pela espera do proxy)"), claude.label)
    XCTAssertTrue(claude.label.contains(", em 1 h 40 min (previsto pela janela de 5 horas)"), claude.label)
    XCTAssertTrue(claude.label.contains("Farol volta ") && claude.label.contains(", em 1 dia e 22 h (previsto pela renovação da semana)"), claude.label)
    XCTAssertFalse(claude.label.contains("Gavea volta"), claude.label)
    XCTAssertTrue(codex.label.contains("Kauri volta ") && codex.label.contains(", em 2 h (previsto pela espera do proxy e janela de 5 horas)"), codex.label)
    checkGeometry(app)
    shot("prazos")

    // "Destacar no resumo" puts the dash under Iris's ring, which keeps its place; it is removed at the end.
    try pin("iris", on: true, app)
    wait(codex, value: "Pro Max:78^|Plus:B2h|Pro Max:!|Free:?,?")
    checkGeometry(app)
    shot("prazos-destaque")
    try pin("iris", on: false, app)
    wait(codex, value: "Pro Max:78|Plus:B2h|Pro Max:!|Free:?,?")
  }

  /// Turns an account's "Destacar no resumo" on or off in the Codex details and closes them.
  private func pin(_ id: String, on: Bool, _ app: XCUIApplication) throws {
    app.buttons["proxy-strip-codex"].tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForExistence(timeout: 10))
    let button = app.buttons["proxy-select-" + id]
    for _ in 0..<20 where !(button.exists && button.isHittable && button.frame.maxY < app.frame.maxY - 45) {
      app.swipeUp(velocity: .slow)
    }
    if button.isSelected != on { button.tap() }
    let selected = NSPredicate(format: "selected == %@", NSNumber(value: on))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: selected, evaluatedWith: button)], timeout: 10), .completed)
    app.buttons["proxy-close"].tap()
    XCTAssertTrue(app.buttons["proxy-strip-codex"].waitForExistence(timeout: 10))
  }

  func testManyAccountsFallBackToCountsInTheSameRow() throws {
    let app = try launch("many")
    defer { app.terminate() }
    let claude = app.buttons["proxy-strip-anthropic"]
    // 16 Max 5x (every third extra one stopped by the 5-hour window), the plan without a name and an unknown one.
    // A plan's label comes back when the states split it: Pro Max ready, then Pro Max needing login.
    wait(claude, value: "5x:100,72,64,50,50,50,50,50,50,50,50,41|Outro:90|Team:40|5x:B45m,B2h,B2h,B3h|20x:E3d,E3d")
    wait(app.buttons["proxy-strip-codex"], value: "Pro Max:64|Plus:33|5x:B3h,E2d|Pro Max:!|5x:?|Free:?,?,?,?,?,?,?,?")
    checkGeometry(app)
    shot("muitas")
  }

  func testLargeTextStacksTheProvidersInsideTheMargins() throws {
    let app = try launch("marks", largeText: true)
    defer { app.terminate() }
    wait(app.buttons["proxy-strip-anthropic"], value: "5x:100,72,64,41,B2h|20x:E3d,E3d")
    checkGeometry(app, stacked: true)
    shot("texto-grande")
  }
}
