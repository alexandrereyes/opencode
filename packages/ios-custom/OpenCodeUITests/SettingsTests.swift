import XCTest

@MainActor final class SettingsTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var run: String { environment["OPENCODE_TEST_RUN_ID"] ?? "onda8" }
  private var manualName: String { "Sandbox manual · " + run }
  private var offlineName: String { "Local indisponível · " + run }
  private var pairedName: String { "Sandbox pareado · " + run }
  private var removableName: String { "Local removível · " + run }
  private func launch(child: Bool = false, override: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url]
    if let override { app.launchArguments += ["-OpenCodeTheme", override] }
    if child { app.launchArguments += ["-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_CHILD"])] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_SETTINGS_TEST_INPUT"] = "1"
    app.launchEnvironment["OPENCODE_PAIRING_PAYLOAD"] = environment["OPENCODE_TEST_PAIRING"]
    app.launch()
    return app
  }
  private func shot(_ name: String) {
    dismissAlert(XCUIApplication())
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func dismissAlert(_ app: XCUIApplication) {
    let close = app.buttons["Fechar alerta"].firstMatch
    if close.exists && close.isHittable {
      close.tap()
      XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }
  }
  private func settings(_ app: XCUIApplication, appearance: Bool = false) {
    dismissAlert(app)
    // Você opens at its root every time: it is a sheet now, not a tab that kept its pushed screen.
    app.openYou()
    if appearance { reveal(app.descendants(matching: .any)["settings-themes"].firstMatch, app: app) }
  }
  func testHeaderAvatarOpensAndClosesYou() throws {
    let app = try launch(override: environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    defer { app.terminate() }
    try app.requireSandbox()
    app.openYou()
    XCTAssertTrue(app.descendants(matching: .any)["settings-themes"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["settings-close"].tap()
    XCTAssertTrue(app.navigationBars["Você"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.accountButton.isHittable)
    app.openYou()
    XCTAssertTrue(app.navigationBars["Você"].exists)
    app.showSessions()
    XCTAssertTrue(app.accountButton.isHittable)
    XCTAssertFalse(app.tabBars.firstMatch.exists)
  }
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    // Você is a sheet over the Sessões list: scroll the topmost list, resolved again before every swipe.
    var list: XCUIElement {
      let lists = app.collectionViews
      return lists.element(boundBy: max(0, lists.count - 1))
    }
    let top = app.navigationBars.firstMatch.frame.maxY
    // Você is a sheet: only the floating voice bar can cover its bottom.
    let bottom = app.frame.maxY - 60
    // A fast swipe down at the top would dismiss the sheet; drag slowly and hold so it only scrolls.
    func scrollTowardTop() {
      let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)), withVelocity: .slow,
        thenHoldForDuration: 0.3)
    }
    if !element.exists { scrollTowardTop() }
    for _ in 0..<20 {
      let frame = element.exists ? element.frame : .zero
      if frame.height > 0 && frame.minY >= top && frame.maxY < bottom && element.isHittable { return }
      if frame.height > 0 && frame.minY < top {
        scrollTowardTop()
        continue
      }
      list.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }
  private func chooseTheme(_ id: String, app: XCUIApplication) {
    reveal(app.descendants(matching: .any)["settings-themes"].firstMatch, app: app)
    app.descendants(matching: .any)["settings-themes"].firstMatch.tap()
    let row = app.buttons["theme-" + id]
    reveal(row, app: app)
    row.tap()
    XCTAssertTrue(row.isSelected)
    shot("themes-" + id)
    app.navigationBars["Temas"].buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Temas"].waitForNonExistence(timeout: 5))
  }
  func testLiveThemesAndAppearancesAcrossScreens() throws {
    let app = try launch()
    XCTAssertTrue(app.accountButton.waitForExistence(timeout: 20))
    settings(app, appearance: true)
    chooseTheme("openchamber", app: app)
    for (family, mode, name) in [("openchamber", "Escuro", "openchamber-dark"),
                                  ("openchamber", "Claro", "openchamber-light"),
                                  ("dracula", "Escuro", "dracula-dark")] {
      if family != "openchamber" { chooseTheme(family, app: app) }
      app.segmentedControls["settings-appearance"].buttons[mode].tap()
      shot("voce-" + name)
      app.descendants(matching: .any)["settings-themes"].firstMatch.tap()
      reveal(app.buttons["theme-" + family], app: app)
      shot("theme-picker-" + name)
      app.navigationBars.buttons.firstMatch.tap()
      reveal(app.descendants(matching: .any)["settings-about"].firstMatch, app: app)
      app.descendants(matching: .any)["settings-about"].firstMatch.tap()
      XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'desenvolvimento' OR value CONTAINS 'desenvolvimento'")).firstMatch.waitForExistence(timeout: 5))
      shot("about-" + name)
      app.navigationBars.buttons.firstMatch.tap()
      app.showSessions()
      shot("sessions-" + name)
      let root = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch
      app.revealSessionRow(root)
      root.tap()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 15))
      XCTAssertTrue(app.staticTexts["Confira a aparência desta conversa."].waitForExistence(timeout: 10))
      shot("conversation-" + name)
      dismissAlert(app)
      app.buttons["Voltar"].tap()
      settings(app, appearance: true)
    }
    chooseTheme("openchamber", app: app)
    app.segmentedControls["settings-appearance"].buttons["Sistema"].tap()
  }
  func testManualServersTestSwitchEditRemoveAndPairing() throws {
    let mode = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch(child: true, override: mode)
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    dismissAlert(app)
    app.buttons["Voltar"].tap()
    settings(app)
    reveal(app.descendants(matching: .any)["settings-servers"].firstMatch, app: app)
    app.descendants(matching: .any)["settings-servers"].firstMatch.tap()
    cleanPreviousTestServers(app)
    reveal(app.descendants(matching: .any)["server-add"].firstMatch, app: app)
    shot("servers-initial-" + mode)
    addServer(app, name: manualName, address: TestSandbox.url,
              password: try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"]), success: true, mode: mode)
    addServer(app, name: offlineName, address: "http://127.0.0.1:9", password: nil, success: false, mode: mode)
    selectServer(offlineName, app: app)
    XCTAssertTrue(app.staticTexts["Desconectado"].waitForExistence(timeout: 15))
    shot("server-offline-" + mode)
    app.showSessions()
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch.exists)
    shot("sessions-offline-clean-" + mode)
    settings(app)
    reveal(app.buttons["settings-servers"], app: app)
    app.buttons["settings-servers"].tap()
    selectServer(manualName, app: app)
    XCTAssertTrue(app.staticTexts["Conectado"].waitForExistence(timeout: 15))
    shot("server-manual-active-" + mode)
    app.showSessions()
    let root = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch
    app.revealSessionRow(root)
    XCTAssertTrue(root.exists)
    settings(app)
    reveal(app.buttons["settings-servers"], app: app)
    app.buttons["settings-servers"].tap()
    let pairing = app.descendants(matching: .any)["server-pair"].firstMatch
    reveal(pairing, app: app)
    pairing.tap()
    XCTAssertTrue(app.textViews["pairing-payload"].waitForExistence(timeout: 5))
    shot("pairing-scanner-equivalent-" + mode)
    app.buttons["pairing-test-input"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == 'Código resgatado'"),
      evaluatedWith: app.textViews["pairing-payload"])], timeout: 20), .completed)
    app.swipeUp(velocity: .slow)
    XCTAssertTrue(app.buttons["pairing-save"].waitForExistence(timeout: 5))
    shot("pairing-redeemed-" + mode)
    app.textFields["pairing-name"].tap()
    app.textFields["pairing-name"].typeText(pairedName)
    app.buttons["pairing-save"].tap()
    selectServer(pairedName, app: app)
    XCTAssertTrue(app.staticTexts["Conectado"].waitForExistence(timeout: 15))
    shot("server-paired-active-" + mode)
    // Edit and remove a non-active server, preserving the built-in entry.
    reveal(app.buttons["Editar " + offlineName], app: app)
    app.buttons["Editar " + offlineName].tap()
    let name = app.textFields["server-name"]
    name.tap()
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: offlineName.count) + removableName)
    app.buttons["server-test"].tap()
    XCTAssertTrue(app.staticTexts["server-test-result"].waitForExistence(timeout: 10))
    app.buttons["server-save"].tap()
    XCTAssertTrue(app.navigationBars["Editar servidor"].waitForNonExistence(timeout: 5))
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND label CONTAINS %@", removableName)).firstMatch
    reveal(row, app: app)
    row.press(forDuration: 1)
    app.buttons["Remover"].tap()
    shot("server-remove-confirmation-" + mode)
    app.buttons["Remover servidor"].tap()
    XCTAssertFalse(row.exists)
  }
  private func cleanPreviousTestServers(_ app: XCUIApplication) {
    for _ in 0..<30 {
      let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND (label BEGINSWITH 'Sandbox manual' OR label BEGINSWITH 'Sandbox pareado' OR label BEGINSWITH 'Local indisponível' OR label BEGINSWITH 'Local removível')")).firstMatch
      guard row.exists else { return }
      reveal(row, app: app)
      row.press(forDuration: 1)
      app.buttons["Remover"].tap()
      app.buttons["Remover servidor"].tap()
    }
  }
  private func addServer(_ app: XCUIApplication, name: String, address: String, password: String?, success: Bool, mode: String) {
    // Native automatic List actions may be exposed as cells, not buttons.
    let add = app.descendants(matching: .any)["server-add"].firstMatch
    reveal(add, app: app)
    add.tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["server-name"].waitForExistence(timeout: 5))
    app.textFields["server-name"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.textFields["server-name"].typeText(name)
    app.textFields["server-address"].tap()
    app.textFields["server-address"].typeText(address)
    if password == nil {
      // The debug-only sandbox prefill is removed for the unreachable/no-password entry.
      app.secureTextFields["server-password"].tap()
      app.secureTextFields["server-password"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: environment["OPENCODE_TEST_PASSWORD"]?.count ?? 0))
    }
    app.buttons["server-test"].tap()
    let result = app.staticTexts["server-test-result"]
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    XCTAssertTrue(result.label.contains(success ? "Conectado" : "Falha"))
    app.swipeUp(velocity: .slow)
    shot("server-add-" + (success ? "success-" : "failure-") + mode)
    app.buttons["server-save"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForNonExistence(timeout: 5))
    // AutoFill may be hosted out of process; a blocked Back button is not proof it is ready.
    if success {
      let decline = [app.buttons["Agora Não"].firstMatch,
        XCUIApplication(bundleIdentifier: "com.apple.SafariViewService").buttons["Agora Não"]]
        .first { $0.waitForExistence(timeout: 5) }
      if let decline {
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"),
          evaluatedWith: decline)], timeout: 5), .completed)
        decline.tap()
        XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
      }
    }
    XCTAssertTrue(add.waitForExistence(timeout: 10))
  }
  private func selectServer(_ title: String, app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND label CONTAINS %@", title)).firstMatch
    reveal(row, app: app)
    row.tap()
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 15))
    reveal(app.buttons["settings-servers"], app: app)
    app.buttons["settings-servers"].tap()
  }
  func testChildPreambleHiddenAndCopyUsesAuthoredText() throws {
    let mode = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch(child: true, override: mode)
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    let prompt = app.staticTexts["Confira apenas o texto autoral do subagente."]
    XCTAssertTrue(prompt.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'You are a subagent spawned' ")).firstMatch.exists)
    shot("child-without-preamble-" + mode)
    prompt.press(forDuration: 1)
    app.buttons["Copiar"].tap()
    XCTAssertTrue(app.staticTexts["Mensagem copiada"].waitForExistence(timeout: 5))
  }
}
